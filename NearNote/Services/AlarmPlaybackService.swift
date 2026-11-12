import Foundation
import AVFoundation
import UIKit
import OSLog

private let alarmLog = Logger(subsystem: "com.wayzs999.arrival", category: "Alarm")

/// 到站发声。
///
/// 一次告警由两段声音组成：**自铃声**（`AlarmChime.wav`，代码生成的 1.16s 双音）→ **语音播报**
/// （`AVSpeechSynthesizer`，中文）。顺序是刻意的：先响铃把人从耳机/口袋里拽出来，再播站名。
///
/// 三个必须知道的约束（都来自 iOS 本身，不是实现偷懒）：
/// 1. **静音拨片无法突破**。`UIBackgroundModes: audio` 只保证「后台能出声」，不保证「静音开关下出声」。
///    真穿透只有 Critical Alerts，需要 Apple 单独审批，个人/企业签名都拿不到。
/// 2. 围栏唤醒后系统只给很短的后台执行窗口，所以进来第一件事就是 `beginBackgroundTask` 续命，
///    否则铃声还没放完 App 就被挂起。
/// 3. 声音能不能在锁屏时响，取决于 `AVAudioSession` 是否在后台仍然 active ——
///    这也是为什么播完必须显式 `setActive(false)`，不还回去会抢占别的 App 的音频。
@MainActor
public final class AlarmPlaybackService: NSObject, ObservableObject {

    public static let shared = AlarmPlaybackService()

    /// UserDefaults 键。用 UserDefaults 而不是 `@AppStorage`：这是服务层，不依赖 SwiftUI。
    public enum DefaultsKey {
        public static let voiceEnabled = "alarm.voiceEnabled"
        public static let chimeEnabled = "alarm.chimeEnabled"
        public static let volume = "alarm.volume"
    }

    /// 播报进行中（UI 可以据此显示"正在播报"）。铃声阶段也算。
    @Published public private(set) var isAnnouncing = false

    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var timeoutTask: Task<Void, Never>?

    private var pendingSpeech: String?
    private var chimePlayed = false

    /// 播报最长占用时长。超过就强制收尾，避免后台任务泄漏把 App 拖死。
    private let announceTimeout: TimeInterval = 12

    private override init() {
        super.init()
        synthesizer.delegate = self
        UserDefaults.standard.register(defaults: [
            DefaultsKey.voiceEnabled: true,
            DefaultsKey.chimeEnabled: true,
            DefaultsKey.volume: 1.0
        ])
    }

    // MARK: - 设置项

    public var isVoiceEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.voiceEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.voiceEnabled) }
    }

    public var isChimeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.chimeEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.chimeEnabled) }
    }

    public var volume: Double {
        get { UserDefaults.standard.double(forKey: DefaultsKey.volume) }
        set { UserDefaults.standard.set(min(max(newValue, 0), 1), forKey: DefaultsKey.volume) }
    }

    // MARK: - 对外入口

    /// 到站：先响铃再播报站名。
    public func announceArrival(stationName: String, extraSentence: String? = nil) {
        announce(Self.arrivalSentence(stationName: stationName, extra: extraSentence))
    }

    /// 通用播报。铃声与语音是否发声各自受设置控制；两者都关时直接返回。
    public func announce(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isChimeEnabled || (isVoiceEnabled && !trimmed.isEmpty) else {
            alarmLog.debug("铃声与语音都已关闭，跳过播报")
            return
        }

        cancelCurrent()

        pendingSpeech = trimmed.isEmpty ? nil : trimmed
        chimePlayed = false
        isAnnouncing = true

        beginBackgroundExecution()
        activateSession()

        if isChimeEnabled, playChime() {
            // 铃声是异步的，语音在 audioPlayerDidFinishPlaying 里接上，避免两段声音叠在一起
            alarmLog.debug("铃声开始")
        } else {
            chimePlayed = true
            speakPending()
        }

        startTimeout()
    }

    /// 只播语音、不响铃。
    ///
    /// 用在 App 在后台/锁屏时：那一刻系统通知本身已经用 `AlarmChime.wav` 响过了，
    /// 再放一次铃声就是双重奏。这里只补人声。
    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isVoiceEnabled, !trimmed.isEmpty else { return }

        cancelCurrent()
        pendingSpeech = trimmed
        chimePlayed = true
        isAnnouncing = true
        beginBackgroundExecution()
        activateSession()
        speakPending()
        startTimeout()
    }

    /// 立刻停止一切声音（用户点通知里的"完成"、手动结束追踪时调用）。
    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
        finishCurrent()
    }

    // MARK: - 文案

    public static func arrivalSentence(stationName: String, extra: String? = nil) -> String {
        let name = stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = name.isEmpty ? "前方到站，请准备下车。" : "前方到站，\(name)，请准备下车。"
        if let extra, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sentence += " " + extra
        }
        return sentence
    }

    // MARK: - 播放内部

    @discardableResult
    private func playChime() -> Bool {
        guard let url = Bundle.main.url(forResource: "AlarmChime", withExtension: "wav") else {
            alarmLog.error("AlarmChime.wav 没打进 Bundle，铃声阶段跳过")
            return false
        }
        do {
            let audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer.delegate = self
            audioPlayer.volume = Float(volume)
            audioPlayer.prepareToPlay()
            audioPlayer.play()
            player = audioPlayer
            return true
        } catch {
            alarmLog.error("铃声播放失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func speakPending() {
        guard let text = pendingSpeech, isVoiceEnabled else {
            finishCurrent()
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        // 优先中文女声；设备没装中文包时退回系统默认声音，不能因此不播
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
            ?? AVSpeechSynthesisVoice(language: "zh-Hans-CN")
        utterance.rate = 0.47
        utterance.pitchMultiplier = 1.0
        utterance.volume = Float(volume)
        utterance.postUtteranceDelay = 0.05
        synthesizer.speak(utterance)
        alarmLog.debug("开始播报：\(text, privacy: .public)")
    }

    // MARK: - 会话与生命周期

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // .spokenAudio：锁屏时继续播、并且会暂停其他有声书/播客
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            alarmLog.error("音频会话激活失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            alarmLog.debug("音频会话归还有告警（无害）：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func beginBackgroundExecution() {
        endBackgroundExecution()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "arrival-announce") { [weak self] in
            Task { @MainActor in
                alarmLog.debug("后台任务到期，强制收尾")
                self?.stop()
            }
        }
    }

    private func endBackgroundExecution() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            let seconds = self?.announceTimeout ?? 12
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.isAnnouncing else { return }
                alarmLog.debug("播报超时，强制收尾")
                self.stop()
            }
        }
    }

    private func cancelCurrent() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
    }

    private func finishCurrent() {
        timeoutTask?.cancel()
        timeoutTask = nil
        pendingSpeech = nil
        chimePlayed = false
        isAnnouncing = false
        deactivateSession()
        endBackgroundExecution()
    }
}

// MARK: - AVAudioPlayerDelegate（铃声放完 → 接语音）

extension AlarmPlaybackService: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            AlarmPlaybackService.shared.chimePlayed = true
            AlarmPlaybackService.shared.speakPending()
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            AlarmPlaybackService.shared.chimePlayed = true
            AlarmPlaybackService.shared.speakPending()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate（语音结束 → 收尾）

extension AlarmPlaybackService: AVSpeechSynthesizerDelegate {
    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in AlarmPlaybackService.shared.finishCurrent() }
    }

    nonisolated public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in AlarmPlaybackService.shared.finishCurrent() }
    }
}
