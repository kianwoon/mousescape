// baseline-guard:allow new standalone XPC protocol file, no prior baseline possible
//
//  ClickAssistXPCProtocol.swift
//  Shared by ClickAssistAgent (client) and ClickAssistResolver.xpc (service).
//
//  PAYLOADS: every non-liveness argument/reply that carries structured data is
//  VERSIONED JSON and includes an `epoch` field identifying the service process
//  instance. `Data` is used because NSXPC cannot carry Swift structs directly.
//  A client must ignore a payload whose `epoch` is not the current service epoch.
//

import Foundation

@objc protocol ClickAssistXPCProtocol {
    /// Liveness probe. The service replies with a short token.
    func ping(reply: @escaping (String) -> Void)
    /// Service identity as JSON {version, pid, epoch}. `epoch` is generated once
    /// at service start, so a client can detect a replaced process.
    func serviceInfo(reply: @escaping (Data) -> Void)

    /// Service → client snapshot publication (one-way semantics). The client
    /// replies an ack so the service can coalesce: while a send is in flight the
    /// service retains only the newest pending snapshot.
    func publishSnapshot(_ data: Data, reply: @escaping (Bool) -> Void)

    /// Client → service activation request. The reply {status, reason} is
    /// ADVISORY ONLY: the client never blocks a gesture on it and never retries.
    func activate(_ requestData: Data, reply: @escaping (Data) -> Void)
}
