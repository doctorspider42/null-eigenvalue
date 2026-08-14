import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Closer to square than the nib's default: the picture is a 2D field the
    // pointer moves through, and a very wide window makes one axis travel
    // twice as far as the other for the same gesture. Centred rather than
    // cascaded, because this is a single-window app and there is nothing for
    // it to cascade away from.
    var frame = self.frame
    frame.size = NSSize(width: 1040, height: 780)
    self.setFrame(frame, display: true)
    self.center()

    // Below roughly this the transport and the row of mood dots stop fitting
    // one above the other.
    self.contentMinSize = NSSize(width: 560, height: 480)

    self.title = "Null Eigenvalue"
    // One theme, always. A light title bar over a near-black picture reads as
    // a strip of somebody else's window rather than as a preference honoured.
    self.appearance = NSAppearance(named: .darkAqua)
    self.backgroundColor = NSColor(red: 3 / 255.0, green: 7 / 255.0,
                                   blue: 12 / 255.0, alpha: 1)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // The one thing the app asks of the window that Flutter cannot do itself.
    // AppKit already owns the animation and the menu bar behaviour, so this is
    // a forwarder rather than an implementation.
    let channel = FlutterMethodChannel(
      name: "nulleigenvalue/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "setFullscreen" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let isFullscreen = self.styleMask.contains(.fullScreen)
      var want = !isFullscreen
      if let args = call.arguments as? [String: Any],
         let value = args["value"] as? Bool {
        want = value
      }
      if want != isFullscreen {
        self.toggleFullScreen(nil)
      }
      result(want)
    }

    super.awakeFromNib()
  }
}
