import Cocoa
import FlutterMacOS
import Network

class MainFlutterWindow: NSWindow {
  private let networkMonitor = NWPathMonitor()
  private var networkChannel: FlutterMethodChannel?
  private var networkAvailable: Bool?
  private var networkWaiters: [FlutterResult] = []

  private func startNetworkMonitor(_ controller: FlutterViewController) {
    networkChannel = FlutterMethodChannel(name: "imbroglio/network",
      binaryMessenger: controller.engine.binaryMessenger)
    networkChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "status", let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      if let available = self.networkAvailable {
        result(available)
      } else {
        self.networkWaiters.append(result)
      }
    }
    networkMonitor.pathUpdateHandler = { [weak self] path in
      DispatchQueue.main.async {
        guard let self = self else { return }
        let available = path.status == .satisfied
        self.networkAvailable = available
        let waiters = self.networkWaiters
        self.networkWaiters.removeAll()
        waiters.forEach { $0(available) }
        self.networkChannel?.invokeMethod("changed", arguments: available)
      }
    }
    networkMonitor.start(queue: DispatchQueue(label: "imbroglio.network"))
  }

  deinit { networkMonitor.cancel() }

  private var loadingView: NSView?
  private var startupChannel: FlutterMethodChannel?

  override func awakeFromNib() {
    let startupBegan = ProcessInfo.processInfo.systemUptime
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // The nib's original content view is replaced above. Route keyboard input
    // to Flutter instead of leaving the window as the first responder.
    initialFirstResponder = flutterViewController.view
    makeFirstResponder(flutterViewController.view)
    startNetworkMonitor(flutterViewController)

    // Show useful native content even before Dart or the debugger is ready.
    if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
      let area = screen.visibleFrame
      let size = NSSize(width: min(1320, max(1, area.width - 32)),
                        height: min(860, max(1, area.height - 32)))
      minSize = NSSize(width: min(960, size.width), height: min(640, size.height))
      setFrame(NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                      width: size.width, height: size.height), display: false)
    }

    let loading = NSView(frame: flutterViewController.view.bounds)
    loading.autoresizingMask = [.width, .height]
    loading.wantsLayer = true
    loading.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    let label = NSTextField(labelWithString: "Imbroglio · 正在加载，请稍候")
    label.font = NSFont.systemFont(ofSize: 16)
    label.translatesAutoresizingMaskIntoConstraints = false
    let spinner = NSProgressIndicator()
    spinner.style = .spinning
    spinner.translatesAutoresizingMaskIntoConstraints = false
    loading.addSubview(label)
    loading.addSubview(spinner)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: loading.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: loading.centerYAnchor, constant: 24),
      spinner.centerXAnchor.constraint(equalTo: loading.centerXAnchor),
      spinner.bottomAnchor.constraint(equalTo: label.topAnchor, constant: -20),
    ])
    spinner.startAnimation(nil)
    flutterViewController.view.addSubview(loading)
    loadingView = loading

    startupChannel = FlutterMethodChannel(name: "imbroglio/startup",
                                          binaryMessenger: flutterViewController.engine.binaryMessenger)
    startupChannel?.setMethodCallHandler { [weak self] call, result in
      guard call.method == "flutterReady" else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.loadingView?.removeFromSuperview()
      self?.loadingView = nil
      if let window = self {
        window.makeFirstResponder(window.contentViewController?.view)
      }
      // Reveal Flutter in place without changing focus or the active Space.
      result(Int((ProcessInfo.processInfo.systemUptime - startupBegan) * 1_000_000))
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    makeKeyAndOrderFront(nil)
  }
}
