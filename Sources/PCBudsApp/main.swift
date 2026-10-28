import AppKit

@main
enum PCBudsAppMain {
    static func main() {
        // A second launch (double click, login item, `open -n`) must not open a second F5 tap.
        if SingleInstance.isAlreadyRunning() { SingleInstance.yieldToRunningCopy() }

        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = PCBudsAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
