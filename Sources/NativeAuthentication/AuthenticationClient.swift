import Foundation

public protocol AuthenticationClientDelegate {
    func authentication(client: AuthenticationClient, updated form: SignInForm)
    func authentication(client: AuthenticationClient, finished token: Token)
    func authentication(client: AuthenticationClient, idp provider: RedirectIDP.Provider, redirectTo url: URL, callback scheme: String)
}

public enum AuthenticationClientError: Error {
    case idpRedirect
}

public class AuthenticationClient: UsesDelegateCollection, ObservableObject {
    public typealias Delegate = AuthenticationClientDelegate
    
    public enum UIState {
        case foreground
        case background
    }

    let provider: any AuthenticationProvider
    public private(set) var form: SignInForm {
        didSet {
            self.delegateCollection.invoke({ $0.authentication(client: self, updated: form) })
        }
    }

    public let delegateCollection = DelegateCollection<AuthenticationClientDelegate>()
    public private(set) var uiState: UIState {
        didSet {
            guard oldValue != uiState else { return }
            
            provider.transitioned(to: uiState)
        }
    }
    
    public init(provider: any AuthenticationProvider) {
        self.uiState = .foreground
        self.form = .empty
        self.provider = provider
        self.provider.add(delegate: self)
    }
    
    @MainActor
    public func signIn() async {
        await provider.signIn()
    }
    
    public func transitioned(to state: UIState) {
        uiState = state
    }
    
    public func idp(_ idp: RedirectIDP.Provider, finished callbackURL: URL) {
        provider.idp(idp, finished: callbackURL)
    }

    public func idp(_ idp: RedirectIDP.Provider, error: Error) {
        provider.idp(idp, error: error)
    }
}

extension AuthenticationClient: AuthenticationProviderDelegate {
    public func authentication(provider: any AuthenticationProvider, finished token: Token) {
        delegateCollection.invoke { $0.authentication(client: self, finished: token) }
    }
    
    public func authentication(provider: any AuthenticationProvider, updated form: SignInForm) {
        delegateCollection.invoke { $0.authentication(client: self, updated: form) }
    }
    
    public func authentication(provider: any AuthenticationProvider, idp: RedirectIDP.Provider, redirectTo url: URL, callback scheme: String) {
        delegateCollection.invoke { $0.authentication(client: self, idp: idp, redirectTo: url, callback: scheme) }
    }
}
