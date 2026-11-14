// html2png <file.html> <out.png> <width>: renders the page in WebKit at that width and saves the whole page.
import AppKit
import WebKit
let args = CommandLine.arguments
let url = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2]), width = CGFloat(Double(args[3]) ?? 1000)
final class Shot: NSObject, WKNavigationDelegate {
  let web: WKWebView
  init(width: CGFloat) {
    web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
    super.init()
    web.navigationDelegate = self
  }
  func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
      w.evaluateJavaScript("Math.ceil((document.getElementById(\"shot\") || document.documentElement).getBoundingClientRect().height)") { h, _ in
        let height = CGFloat((h as? Double) ?? 800)
        w.frame = NSRect(x: 0, y: 0, width: w.frame.width, height: height)
        let cfg = WKSnapshotConfiguration()
        cfg.rect = NSRect(x: 0, y: 0, width: w.frame.width, height: height)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          w.takeSnapshot(with: cfg) { img, err in
            guard let img = img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { print("failed", err as Any); exit(1) }
            try! png.write(to: out)
            print("wrote", out.lastPathComponent, rep.pixelsWide, rep.pixelsHigh)
            exit(0)
          }
        }
      }
    }
  }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let shot = Shot(width: width)
shot.web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
app.run()
