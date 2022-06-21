//
// Copyright (c) 2021-Present, Okta, Inc. and/or its affiliates. All rights reserved.
// The Okta software accompanied by this notice is provided pursuant to the Apache License, Version 2.0 (the "License.")
//
// You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0.
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
// WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//
// See the License for the specific language governing permissions and limitations under the License.
//

import Foundation
@_exported import AuthFoundation

/// An authentication flow used to authenticate users using the Okta Identity Engine.
///
/// This permits a user to be authenticated using a dynamic and customizable workflow that is driven by server-side policy configuration. A user is given choices in how they authenticate, how they verify one or more authentication factors, and can enable self-service registration and authenticator enrollment.
///
/// This class is used to communicate which application, defined within Okta, the user is being authenticated with. From this point a workflow is initiated, consisting of a series of authentication ``Remediation`` steps. At each step, your application can introspect the ``Response`` object to determine which UI should be presented to your user to guide them through to login.
public final class IDXAuthenticationFlow: AuthenticationFlow {
    /// Options to use when initiating an ``IDXAuthenticationFlow``.
    public enum Option: String {
        /// Option used when a client needs to supply its own custom state value when initiating an authenticaiton flow.
        case state
        
        /// Option used when a user is authenticating using a recovery token.
        case recoveryToken = "recovery_token"
    }
    
    /// The type used for the completion  handler result from any method that returns an ``Response``.
    /// - Parameters:
    ///   - response: The ``Response`` object that describes the next workflow steps.
    ///   - error: Describes the error that occurred, or `nil` if the request was successful.
    public typealias ResponseResult = (Result<Response, IDXAuthenticationFlowError>) -> Void

    /// The type used for the completion  handler result from any method that returns a `Token`.
    /// - Parameters:
    ///   - token: The `Token` object created when the token is successfully exchanged.
    ///   - error: Describes the error that occurred, or `nil` if the request was successful.
    public typealias TokenResult = (Result<Token, IDXAuthenticationFlowError>) -> Void

    /// The OAuth2Client this authentication flow will use.
    public let client: OAuth2Client
    
    /// The application's redirect URI.
    public let redirectUri: URL

    /// Any additional query string parameters you would like to supply to the authorization server.
    public let additionalParameters: [String: String]?

    /// Indicates whether or not this flow is currently in the process of authenticating a user.
    public private(set) var isAuthenticating: Bool = false {
        didSet {
            guard oldValue != isAuthenticating else {
                return
            }
            
            if isAuthenticating {
                delegateCollection.invoke { $0.authenticationStarted(flow: self) }
            } else {
                delegateCollection.invoke { $0.authenticationFinished(flow: self) }
            }
        }
    }

    /// The current context for the authentication session.
    ///
    /// This value is used when resuming authentication at a later date or after app launch, and to ensure the final token exchange can be completed.
    public internal(set) var context: Context?
    
    /// Convenience initializer to construct an authentication flow from variables.
    /// - Parameters:
    ///   - issuer: The issuer URL.
    ///   - clientId: The client ID
    ///   - scopes: The scopes to request
    ///   - redirectUri: The redirect URI for the client.
    public convenience init(issuer: URL,
                            clientId: String,
                            scopes: String,
                            redirectUri: URL,
                            additionalParameters: [String: String]? = nil)
    {
        self.init(redirectUri: redirectUri,
                  additionalParameters: additionalParameters,
                  client: OAuth2Client(baseURL: issuer,
                                       clientId: clientId,
                                       scopes: scopes))
    }
    
    /// Initializer to construct an authentication flow from a pre-defined configuration and client.
    /// - Parameters:
    ///   - configuration: The configuration to use for this authentication flow.
    ///   - client: The `OAuth2Client` to use with this flow.
    public init(redirectUri: URL,
                additionalParameters: [String: String]? = nil,
                client: OAuth2Client)
    {
        // Ensure this SDK's static version is included in the user agent.
        SDKVersion.register(sdk: Version)

        self.client = client
        self.redirectUri = redirectUri
        self.additionalParameters = additionalParameters
        
        client.add(delegate: self)
    }
    
    /// Starts a new authentication session. If the client is able to successfully interact with Okta Identity Engine, a ``context-swift.property`` is assigned, and the initial ``Response`` is returned.
    /// - Parameters:
    ///   - options: Options to include within the OAuth2 transaction.
    ///   - completion: Completion block to be invoked when the session is started.
    public func start(options: [Option: String]? = nil,
                      completion: @escaping ResponseResult)
    {
        if isAuthenticating {
            cancel()
        }
        
        // Ensure we have, at minimum, a state value
        let state = options?[.state] ?? UUID().uuidString
        var options = options ?? [:]
        options[.state] = state
        
        guard let pkce = PKCE() else {
            completion(.failure(.platformUnsupported))
            return
        }
        
        self.isAuthenticating = true
        let request = InteractRequest(baseURL: client.baseURL,
                                      clientId: client.configuration.clientId,
                                      scope: client.configuration.scopes,
                                      redirectUri: redirectUri,
                                      options: options,
                                      pkce: pkce)
        request.send(to: client) { result in
            switch result {
            case .failure(let error):
                self.cancel()
                self.send(error: .apiError(error), completion: completion)
            case .success(let response):
                let context = Context(interactionHandle: response.result.interactionHandle,
                                      state: state,
                                      pkce: pkce)
                self.context = context
                self.resume(completion: completion)
            }
        }
    }
    
    /// Resumes the authentication state to identify the available remediation steps.
    ///
    /// This method is usually performed after an ``IDXAuthenticationFlow`` is created in ``start(options:completion:)``, but can also be called at any time to identify what next remediation steps are available to the user.
    /// - Important:
    /// If a completion handler is not provided, you should ensure that you implement the ``IDXAuthenticationFlowDelegate`` methods to process any response or error returned from this call.
    /// - Parameters:
    ///   - completion: Optional completion handler invoked when a response is received.
    public func resume(completion: ResponseResult? = nil) {
        guard let context = context else {
            send(error: .invalidContext, completion: completion)
            return
        }
        
        let request: IntrospectRequest
        do {
            request = try IntrospectRequest(baseURL: client.baseURL,
                                            interactionHandle: context.interactionHandle)
        } catch let error as IDXAuthenticationFlowError {
            send(error: error, completion: completion)
            return
        } catch {
            send(error: .internalError(error), completion: completion)
            return
        }
        
        request.send(to: client) { result in
            switch result {
            case .failure(let error):
                self.send(error: .apiError(error),
                          completion: completion)
            case .success(let response):
                do {
                    self.send(response: try Response(flow: self, ion: response.result),
                              completion: completion)
                } catch let error as APIClientError {
                    self.send(error: .apiError(error), completion: completion)
                    return
                } catch {
                    self.send(error: .internalError(error), completion: completion)
                    return
                }
            }
        }
    }
    
    /// Evaluates the given redirect URL to determine what next steps can be performed. This is usually used when receiving a redirection from an IDP authentication flow.
    /// - Parameters:
    ///   - url: URL with the app’s custom scheme. The value must match one of the authorized redirect URIs, which are configured in Okta Admin Console.
    /// - Returns: Result of parsing the given redirect URL.
    public func redirectResult(for url: URL) -> RedirectResult {
        guard let context = context else {
            return .invalidContext
        }

        guard let redirect = Redirect(url: url),
              let originalRedirect = Redirect(url: redirectUri) else
        {
            return .invalidRedirectUrl
        }
        
        guard originalRedirect.scheme == redirect.scheme &&
                originalRedirect.path == redirect.path else
        {
            return .invalidRedirectUrl
        }
        
        if context.state != redirect.state {
            return .invalidContext
        }
        
        if redirect.interactionCode != nil {
            return .authenticated
        }
        
        if redirect.interactionRequired {
            return .remediationRequired
        }
        
        return .invalidContext
    }
    
    /// Exchanges the redirect URL with a token.
    ///
    /// Once the ``redirectResult(for:)`` method returns ``RedirectResult/authenticated``, the developer can exchange that redirect URL for a valid token by using this method.
    /// - Parameters:
    ///   - url: URL with the app’s custom scheme. The value must match one of the authorized redirect URIs, which are configured in Okta Admin Console.
    ///   - completion: Optional completion handler invoked when a token, or error, is received.
    public func exchangeCode(redirect url: URL,
                             completion: TokenResult? = nil) {
        guard let context = context else {
            send(error: .invalidContext, completion: completion)
            return
        }
        
        guard let redirect = Redirect(url: url) else {
            send(error: .internalMessage("Invalid redirect url"), completion: completion)
            return
        }
        
        guard let interactionCode = redirect.interactionCode else {
            send(error: .internalMessage("Interaction code is missed"), completion: completion)
            return
        }

        client.openIdConfiguration { result in
            switch result {
            case .success(let configuration):
                let request = RedirectURLTokenRequest(openIdConfiguration: configuration,
                                                      clientId: self.client.configuration.clientId,
                                                      scope: self.client.configuration.scopes,
                                                      redirectUri: self.redirectUri.absoluteString,
                                                      interactionCode: interactionCode,
                                                      pkce: context.pkce)
                self.client.exchange(token: request) { result in
                    switch result {
                    case .success(let token):
                        self.send(response: token.result, completion: completion)
                    case .failure(let error):
                        self.send(error: .apiError(error), completion: completion)
                    }
                }
            case .failure(let error):
                self.send(error: .internalError(error), completion: completion)
            }
        }
    }
    
    /// Cancels the current authentication transaction.
    public func cancel() {
        reset()
    }
    
    /// Resets the authentication flow to its original state.
    public func reset() {
        context = nil
        isAuthenticating = false
    }

    // MARK: Private properties / methods
    public let delegateCollection = DelegateCollection<IDXAuthenticationFlowDelegate>()
}

#if swift(>=5.5.1) && !os(Linux)
@available(iOS 15.0, tvOS 15.0, macOS 12.0, *)
extension IDXAuthenticationFlow {
    /// Starts a new authentication session using the given configuration values. If the client is able to successfully interact with Okta Identity Engine, a new client instance is returned to the caller.
    /// - Parameters:
    ///   - configuration: Configuration describing the app settings to contact.
    ///   - options: Options to include within the OAuth2 transaction.
    /// - Returns: A ``Response``.
    public func start(options: [Option: String]? = nil) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            start(options: options) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Resumes the authentication state to identify the available remediation steps.
    ///
    /// This method can be called at any time to identify what next remediation steps are available to the user.
    /// - Returns: A response showing the user's next steps.
    public func resume() async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            resume() { result in
                continuation.resume(with: result)
            }
        }
    }
    
    /// Exchanges the redirect URL with a token.
    ///
    /// Once the ``redirectResult(for:)`` method returns ``RedirectResult/authenticated``, the developer can exchange that redirect URL for a valid token by using this method.
    /// - Parameters:
    ///   - url: URL with the app’s custom scheme. The value must match one of the authorized redirect URIs, which are configured in Okta Admin Console.
    public func exchangeCode(redirect url: URL) async throws -> Token {
        try await withCheckedThrowingContinuation { continuation in
            exchangeCode(redirect: url) { result in
                continuation.resume(with: result)
            }
        }
    }
}
#endif

extension IDXAuthenticationFlow: UsesDelegateCollection {
    public typealias Delegate = IDXAuthenticationFlowDelegate
}

extension IDXAuthenticationFlow: OAuth2ClientDelegate {
    
}

extension OAuth2Client {
    public func idxFlow(
        redirectUri: URL,
        additionalParameters: [String: String]? = nil) -> IDXAuthenticationFlow
    {
        IDXAuthenticationFlow(redirectUri: redirectUri,
                              additionalParameters: additionalParameters,
                              client: self)
    }
}

class Foo: AnyObject, IDXAuthenticationFlowDelegate {
    func authentication<Flow>(flow: Flow, received response: Response) where Flow : IDXAuthenticationFlow {
        // If login is successful, immediately exchange it for a token.
        guard !response.isLoginSuccessful else {
            response.exchangeCode()
            return
        }
        
        // Identify the user
        if let remediation = response.remediations[.identify] {
            remediation["identifier"]?.value = username
            remediation["credentials.passcode"]?.value = password
            remediation.proceed()
        }
        
        // If the password is requested on a separate "page", supply it there.
        else if let remediation = response.remediations[.challengeAuthenticator],
                response.authenticators.current?.type == .password
        {
            remediation["credentials.passcode"]?.value = password
            remediation.proceed()
        }
        
        // Handle other scenarios / remediation states here...
    }
    
    func authentication<Flow>(flow: Flow, received token: Token) where Flow : IDXAuthenticationFlow {
        // Login succeeded, with the given token.
        do {
            try Credential.store(token)
        } catch {
            // Handle with errors
        }
    }
    
    func authentication<Flow>(flow: Flow, received error: OAuth2Error) {
        // Handle the error
    }
    
    
}

/// Delegate protocol that can be used to receive updates from the ``IDXAuthenticationFlow`` through the process of a user's authentication.
public protocol IDXAuthenticationFlowDelegate: AuthenticationDelegate {
    /// Called before authentication begins.
    /// - Parameters:
    ///   - flow: The authentication flow that has started.
    func authenticationStarted<Flow: IDXAuthenticationFlow>(flow: Flow)

    /// Called after authentication completes.
    /// - Parameters:
    ///   - flow: The authentication flow that has finished.
    func authenticationFinished<Flow: IDXAuthenticationFlow>(flow: Flow)

    /// Message sent when an error is received at any point during the authentication process.
    /// - Parameters:
    ///   - client: ``IDXAuthenticationFlow`` sending the error.
    ///   - error: The error that was received.
    func authentication<Flow: IDXAuthenticationFlow>(flow: Flow, received error: IDXAuthenticationFlowError)
    
    /// Informs the delegate when an IDX response is received, either through an ``IDXAuthenticationFlow/resume()`` or ``Remediation/proceed(completion:)`` call.
    /// - Parameters:
    ///   - client: ``IDXAuthenticationFlow`` receiving the response.
    ///   - response: The response that was received.
    func authentication<Flow: IDXAuthenticationFlow>(flow: Flow, received response: Response)
    
    /// Informs the delegate when authentication is successful, and the token is returned.
    /// - Parameters:
    ///   - client: ``IDXAuthenticationFlow`` receiving the token.
    ///   - token: The token object describing the user's credentials.
    func authentication<Flow: IDXAuthenticationFlow>(flow: Flow, received token: Token)
}

/// Errors reported from ``IDXAuthenticationFlow``.
public enum IDXAuthenticationFlowError: Error {
    case invalidContext
    case invalidFlow
    case platformUnsupported
    case invalidUrl
    case cannotCreateRequest
    case invalidHTTPResponse
    case invalidResponseData
    case invalidRequestData
    case serverError(message: String, localizationKey: String, type: String)
    case apiError(_: APIClientError)
    case internalError(_: Error)
    case internalMessage(_: String)
    case oauthError(summary: String, code: String?, errorId: String?)
    case invalidParameter(name: String)
    case invalidParameterValue(name: String, type: String)
    case parameterImmutable(name: String)
    case missingRequiredParameter(name: String)
    case missingRemediationOption(name: String)
    case unknownRemediationOption(name: String)
    case successResponseMissing
    case missingRefreshToken
    case missingRelatedObject
}
