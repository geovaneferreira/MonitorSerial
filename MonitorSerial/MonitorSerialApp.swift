//
//  MonitorSerialApp.swift
//  MonitorSerial
//
//  Created by Geovane Ferreira on 26/03/26.
//

import SwiftUI
import AppKit

@main
struct MonitorSerialApp: App {
    init() {
        if let dockIcon = NSImage(named: "SerialMonitorLogo") {
            NSApplication.shared.applicationIconImage = dockIcon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
