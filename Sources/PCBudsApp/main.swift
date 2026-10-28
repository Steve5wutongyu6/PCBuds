import AppKit

@main
enum PCBudsAppMain {
    static func main() {
        // A second launch (double click, login item, `open -n`) must not open a second F5 tap.
        if SingleInstance.isAlreadyRunning() { SingleInstance.yieldToRunningCopy() }

        let application = NSApplication.shared
        // The app stays out of the Dock and the menu bar entirely: `Resources/Info.plist` ships
        // `LSUIElement`, and forcing .accessory here would add nothing but a Dock-less agent.
        let delegate = PCBudsAppDelegate()
        application.delegate = delegate
        application.run()
    }
}
