// baseline-guard:allow new file for ClickAssistAgent target (no prior baseline)
//
//  AgentLog.swift
//  ClickAssistAgent
//
//  Minimal logging shim so the shared ClickAssistEngine sources compile unchanged
//  in the agent target. The app target supplies its own DebugLogger implementation.
//

import Foundation

func debugLog(_ message: String) {
    FileHandle.standardError.write(Data(("[ClickAssistAgent] " + message + "\n").utf8))
}
