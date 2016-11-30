// OAuth2SessionSpec.swift
//
// Copyright (c) 2016 Auth0 (http://auth0.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Quick
import Nimble
import SafariServices
import OHHTTPStubs

@testable import Auth0

private let ClientId = "CLIENT_ID"
private let Domain = URL(string: "https://samples.auth0.com")!

class MockSafariViewController: SFSafariViewController {
    var presenting: UIViewController? = nil

    override var presentingViewController: UIViewController? {
        return presenting ?? super.presentingViewController
    }
}

private let RedirectURL = URL(string: "https://samples.auth0.com/callback")!

class OAuth2SessionSpec: QuickSpec {

    override func spec() {

        var result: Result<Credentials>? = nil
        let callback: (Result<Credentials>) -> () = { result = $0 }
        let controller = MockSafariViewController(url: URL(string: "https://auth0.com")!)
        let handler = ImplicitGrant()
        let session = SafariSession(controller: controller, redirectURL: RedirectURL, handler: handler, finish: callback, logger: nil)

        beforeEach {
            result = nil
        }

        context("SFSafariViewControllerDelegate") {
            var session: SafariSession!

            beforeEach {
                controller.delegate = nil
                session = SafariSession(controller: controller, redirectURL: RedirectURL, handler: handler, finish: callback, logger: nil)
            }

            it("should set itself as delegate") {
                expect(controller.delegate).toNot(beNil())
            }

            it("should send cancelled event") {
                session.safariViewControllerDidFinish(controller)
                expect(result).toEventually(beFailure())
            }
        }

        describe("resume:options") {

            beforeEach {
                controller.presenting = MockViewController()
            }

            it("should return true if URL matches redirect URL") {
                expect(session.resume(URL(string: "https://samples.auth0.com/callback?access_token=ATOKEN&token_type=bearer")!)).to(beTrue())
            }

            it("should return false when URL does not match redirect URL") {
                expect(session.resume(URL(string: "https://auth0.com/mobile?access_token=ATOKEN&token_type=bearer")!)).to(beFalse())
            }

            context("response_type=token") {

                let session = SafariSession(controller: controller, redirectURL: RedirectURL, handler: ImplicitGrant() , finish: callback, logger: nil)

                it("should not return credentials from query string") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback?access_token=ATOKEN&token_type=bearer")!)
                    expect(result).toEventuallyNot(haveCredentials())
                }

                it("should return credentials from fragment") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#access_token=ATOKEN&token_type=bearer")!)
                    expect(result).toEventually(haveCredentials())
                }

                it("should not return error from query string") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback?error=error&error_description=description")!)
                    expect(result).toEventuallyNot(haveAuthenticationError(code: "error", description: "description"))
                }

                it("should return error from fragment") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#error=error&error_description=description")!)
                    expect(result).toEventually(haveAuthenticationError(code: "error", description: "description"))
                }

                it("should fail if values from fragment are invalid") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#access_token=")!)
                    expect(result).toEventually(beFailure())
                }
            }

            context("response_type=code") {

                let generator = A0SHA256ChallengeGenerator()
                let session = SafariSession(controller: controller, redirectURL: RedirectURL, handler: PKCE(authentication: Auth0Authentication(clientId: ClientId, url: Domain), redirectURL: RedirectURL, generator: generator), finish: callback, logger: nil)
                let code = "123456"

                beforeEach {
                    stub(condition: isToken("samples.auth0.com") && hasAtLeast(["code": code, "code_verifier": generator.verifier, "grant_type": "authorization_code", "redirect_uri": RedirectURL.absoluteString])) { _ in return authResponse(accessToken: "AT", idToken: "IDT") }.name = "Code Exchange Auth"

                }

                afterEach {
                    OHHTTPStubs.removeAllStubs()
                    stub(condition: isHost("samples.auth0.com")) { _ in
                        return OHHTTPStubsResponse.init(error: NSError(domain: "com.auth0", code: -99999, userInfo: nil))
                        }.name = "YOU SHALL NOT PASS!"
                }

                it("should return credentials from query string") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback?code=\(code)")!)
                    expect(result).toEventually(haveCredentials())
                }

                it("should return credentials from query when fragment is available") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback?code=\(code)#_=_")!)
                    expect(result).toEventually(haveCredentials())
                }

                it("should return credentials from fragment") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#code=\(code)")!)
                    expect(result).toEventually(haveCredentials())
                }

                it("should return error from query string") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback?error=error&error_description=description")!)
                    expect(result).toEventually(haveAuthenticationError(code: "error", description: "description"))
                }

                it("should return error from fragment") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#error=error&error_description=description")!)
                    expect(result).toEventually(haveAuthenticationError(code: "error", description: "description"))
                }

                it("should fail if values from fragment are invalid") {
                    let _ = session.resume(URL(string: "https://samples.auth0.com/callback#code=")!)
                    expect(result).toEventually(beFailure())
                }
            }

            context("with state") {
                let session = SafariSession(controller: controller, redirectURL: RedirectURL, state: "state", handler: handler, finish: {
                    result = $0
                }, logger: nil)

                it("should not handle url when state in url is missing") {
                    let handled = session.resume(URL(string: "https://samples.auth0.com/callback?access_token=ATOKEN&token_type=bearer")!)
                    expect(handled).to(beFalse())
                    expect(result).toEventually(beNil())
                }

                it("should not handle url when state in url does not match one in session") {
                    let handled = session.resume(URL(string: "https://samples.auth0.com/callback?access_token=ATOKEN&token_type=bearer&state=another")!)
                    expect(handled).to(beFalse())
                    expect(result).toEventually(beNil())
                }

            }
        }

    }

}
