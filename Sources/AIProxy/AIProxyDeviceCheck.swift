//
//  AIProxyDeviceCheck.swift
//
//
//  Created by Lou Zell on 6/23/24.
//

import Foundation
import DeviceCheck
import OSLog


nonisolated private let deviceCheckWarning = """
    AIProxy warning: DeviceCheck is not available on this device.

    To use AIProxy on an iOS simulator, set an AIPROXY_DEVICE_CHECK_BYPASS environment variable.

    See the README at https://github.com/lzell/AIProxySwift for instructions.
    """


enum AIProxyDeviceCheck {
    /// Internal credential-only injection. Production uses DCDevice's completion callback.
    typealias TokenGenerator = @AIProxyActor @Sendable (
        @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Void

    /// Gets a base64 encoded DeviceCheck token for this device, if possible.
    /// On iOS simulators, the return value will be nil and a log message will be written to console.
    ///
    /// If you are testing AIProxy on a simulator, please see the README.md file for instructions
    /// on adding a DeviceCheck bypass token to your Xcode env variables.
    ///
    /// It is important that you don't let a DeviceCheck bypass token slip into your production codebase.
    /// If you do, an attacker can easily use it themselves to bypass DeviceCheck. Your bypass token is intended
    /// to only be used by developers of your app, and is intended to only be included as a an environment variable.
    ///
    /// - Returns: A base 64 encoded DeviceCheck token, if possible
    @AIProxyActor static func getToken(
        forClient clientID: String?,
        tokenGenerator: TokenGenerator? = nil
    ) async throws -> String? {
        try Task.checkCancellation()
        do {
            let data: Data
            if let tokenGenerator {
                data = try await DeviceCheckTokenRequest().value(using: tokenGenerator)
            } else {
                // Keep the existing optional singleton handling for devices where DCDevice is unavailable.
                let _dcDevice: DCDevice? = DCDevice.current
                guard let dcDevice = _dcDevice else {
                    logIf(.error)?.error("DCDevice singleton is not available. Please contact Lou if you can reproduce this!")
                    await ClientLibErrorLogger.logDeviceCheckSingletonIsNil(clientID: clientID)
                    try Task.checkCancellation()
                    return nil
                }

                guard dcDevice.isSupported else {
                    if ProcessInfo.processInfo.environment["AIPROXY_DEVICE_CHECK_BYPASS"] == nil {
                        logIf(.warning)?.warning("\(deviceCheckWarning, privacy: .public)")
                    }
                    #if !targetEnvironment(simulator) && !DEBUG
                    await ClientLibErrorLogger.logDeviceCheckNotSupported(clientID: clientID)
                    #endif
                    try Task.checkCancellation()
                    return nil
                }
                data = try await DeviceCheckTokenRequest().value { completion in
                    dcDevice.generateToken(completionHandler: completion)
                }
            }
            try Task.checkCancellation()
            return data.base64EncodedString()
        } catch is CancellationError {
            // Cancellation is an operation outcome, not a DeviceCheck failure or logging event.
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            logIf(.error)?.error("Could not create DeviceCheck token. Are you using an explicit bundle identifier?")
            #if !targetEnvironment(simulator) && !DEBUG
            await ClientLibErrorLogger.logDeviceCheckCouldNotGenerateToken(error.localizedDescription, clientID: clientID)
            #endif
            try Task.checkCancellation()
            return nil
        }
    }
}

/// Owns only the SDK continuation. DeviceCheck does not expose an OS-operation cancellation API.
@AIProxyActor private final class DeviceCheckTokenRequest {
    private var continuation: CheckedContinuation<Data, any Error>?
    private var settled = false

    func value(
        using generateToken: @AIProxyActor (@escaping @Sendable (Data?, (any Error)?) -> Void) -> Void
    ) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !settled, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                generateToken { [weak self] data, error in
                    // An OS-owned late callback holds neither the SDK continuation nor its request task.
                    Task { @AIProxyActor [weak self] in
                        if let error {
                            self?.finish(.failure(error))
                        } else if let data {
                            self?.finish(.success(data))
                        } else {
                            self?.finish(.failure(AIProxyError.deviceCheckIsUnavailable))
                        }
                    }
                }
            }
        } onCancel: {
            // Retain this holder while the cancellation handler is registered; the OS callback stays weak.
            Task { @AIProxyActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Data, any Error>) {
        guard !settled else { return }
        settled = true
        let waiting = continuation
        continuation = nil
        waiting?.resume(with: result)
    }
}
