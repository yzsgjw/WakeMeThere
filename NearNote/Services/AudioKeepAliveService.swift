import Foundation
import AVFoundation
import OSLog

private let keepAliveLog = Logger(subsystem: "com.wayzs999.arrival", category: "KeepAlive")

/// 静音保活。
///
/// **它解决什么问题**：iOS 在围栏唤醒后只给很短的后台执行窗口（十几秒级），一旦没有活跃的音频会话，
/// 系统随时可以把 App 挂起。围栏下一次触发是几十秒到几分钟之后——如果那时 App 已经被挂起，
/// 告警就只能靠系统那条通知，我们的语音、灵动岛接力、多站切换全都不会执行。
/// 所以追踪期间用一个**恒为零的 PCM 缓冲循环播放**，让 App 一直保有"正在放音频"的身份，
/// 从而不被挂起。
///
/// **它为什么不会影响你听歌、刷视频**：音频会话用 `.mixWithOthers`。
/// 混音模式下我们不独占播放通道、不暂停、不压低别人的声音，自己又不发出任何声音（缓冲全零）。
/// 唯一会让音乐变小声的时刻是**到站播报的那几秒**——那时 `AlarmPlaybackService` 会临时切成
/// `.duckOthers`（压低而非暂停），播完立刻归还，音乐自动恢复原音量。
///
/// **它的代价**：耗电。播放会话本身不贵，但 App 不再被挂起，定位与围栏的维持成本会体现出来，
/// 大致 1~2%/小时。所以绑在「开始追踪 → 结束追踪」上，不追踪就不跑。
@MainActor
public final class AudioKeepAliveService: ObservableObject {

    public static let shared = AudioKeepAliveService()

    public enum DefaultsKey {
        /// 默认开。用户在设置里可以关掉换续航。
        public static let enabled = "alarm.keepAliveEnabled"
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var isPausedForAnnouncement = false

    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var interruptionObserver: NSObjectProtocol?
    private var wantsToRun = false

    private init() {
        UserDefaults.standard.register(defaults: [DefaultsKey.enabled: true])
        observeInterruptions()
    }

    // MARK: - 对外

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: DefaultsKey.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.enabled)
            if newValue {
                if wantsToRun { start() }
            } else {
                stop()
            }
        }
    }

    /// 追踪开始时调用。用户关了开关就什么都不做。
    public func startIfNeeded() {
        guard isEnabled else {
            keepAliveLog.debug("用户已关闭静音保活")
            return
        }
        start()
    }

    /// 结束追踪时调用。
    public func stop() {
        wantsToRun = false
        isPausedForAnnouncement = false
        teardown()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        keepAliveLog.debug("静音保活已停止")
    }

    /// 播报前让路：先停掉自己的静音引擎，避免和播报抢同一个会话。
    public func pauseForAnnouncement() {
        guard engine != nil else { return }
        isPausedForAnnouncement = true
        teardown()
    }

    /// 播报结束后接管回来。
    public func resumeAfterAnnouncement() {
        guard isPausedForAnnouncement else { return }
        isPausedForAnnouncement = false
        if wantsToRun { start() }
    }

    // MARK: - 引擎

    private func start() {
        wantsToRun = true
        guard engine == nil else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            // .mixWithOthers 是这里的命门：换成就没有它，你的音乐会立刻停。
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            keepAliveLog.error("静音保活会话启动失败：\(error.localizedDescription, privacy: .public)")
            return
        }

        let audioEngine = AVAudioEngine()
        let mixer = audioEngine.mainMixerNode
        var format = mixer.outputFormat(forBus: 0)
        if format.sampleRate <= 0 || format.channelCount == 0 {
            // 会话刚激活时偶尔拿不到有效格式，退回标准 44.1k 立体声
            format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) ?? format
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                           frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
            keepAliveLog.error("静音缓冲分配失败")
            return
        }
        // 新分配的 PCM 缓冲在 Swift 里是全零 —— 这就是「静音」的实现，不需要额外音频文件
        buffer.frameLength = buffer.frameCapacity

        let playerNode = AVAudioPlayerNode()
        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode, to: mixer, format: format)

        do {
            try audioEngine.start()
        } catch {
            keepAliveLog.error("静音保活引擎启动失败：\(error.localizedDescription, privacy: .public)")
            return
        }

        playerNode.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
        playerNode.play()

        engine = audioEngine
        node = playerNode
        isRunning = true
        keepAliveLog.debug("静音保活运行中（混音模式，不影响其他 App）")
    }

    private func teardown() {
        node?.stop()
        engine?.stop()
        node = nil
        engine = nil
        isRunning = false
    }

    // MARK: - 中断（来电、闹钟、其他 App 抢占）

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // 来电话、闹钟响：让路，别跟系统抢
            keepAliveLog.debug("音频中断开始，静音保活临时停止")
            teardown()
        case .ended:
            guard wantsToRun, !isPausedForAnnouncement else { return }
            keepAliveLog.debug("音频中断结束，恢复静音保活")
            start()
        @unknown default:
            break
        }
    }
}
