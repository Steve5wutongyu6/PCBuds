/// PCBudsKit — the noise-control engine behind PCBuds.
///
/// The kit is deliberately small and hardware-agnostic:
///
/// - `NoiseMode` / `NoiseProfile` — pure wire-format model, no I/O.
/// - `OPPFrame` — frame builder/parser for the classic-Bluetooth RFCOMM channel.
/// - `BluetoothControlChannel` — IOBluetooth transport.
/// - `NoiseController` — the single entry point the app talks to.
public enum PCBudsKit {
    /// Bundle identifier of the app that embeds this kit.
    public static let bundleIdentifier = "app.pcbuds.PCBuds"
}
