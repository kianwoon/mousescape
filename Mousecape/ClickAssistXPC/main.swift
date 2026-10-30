// baseline-guard:allow new standalone XPC service entry point, no prior baseline possible
//
//  main.swift
//  ClickAssistResolver.xpc
//
//  Structural stub: an NSXPCListener that advertises the shared protocol. No
//  resolver logic lives here yet (A1b migrates the AX walk).
//

import Foundation

private final class ClickAssistResolverService: NSObject, ClickAssistXPCProtocol {
    /// Generated once at service start: identifies THIS process instance.
    private let epoch = UUID().uuidString

    func ping(reply: @escaping (String) -> Void) {
        reply("pong")
    }

    func serviceInfo(reply: @escaping (Data) -> Void) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"
        let info: [String: Any] = [
            "version": version,
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "epoch": epoch,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
        reply(data)
    }
}

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ClickAssistXPCProtocol.self)
        newConnection.exportedObject = ClickAssistResolverService()
        newConnection.resume()
        return true
    }
}

private let listener = NSXPCListener.service()
private let delegate = ServiceDelegate()
listener.delegate = delegate
listener.resume()
