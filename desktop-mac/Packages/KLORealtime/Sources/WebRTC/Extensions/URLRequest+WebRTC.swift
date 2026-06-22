import Core
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

fileprivate let baseURL = URL(string: "https://api.openai.com/v1/realtime/calls")!

package extension URLRequest {
	static func webRTCConnectionRequest(ephemeralKey: String, model: Model) -> URLRequest {
		// v2 (GA) rejects `?model=` on /v1/realtime/calls with HTTP 400.
		// The model is already bound to the ephemeral key when our server
		// mints it via /v1/realtime/client_secrets. Including the query
		// param here was the preview-era convention and silently broke
		// the SDP exchange after the GA cutover.
		var request = URLRequest(url: baseURL)

		request.httpMethod = "POST"
		request.setValue("Bearer \(ephemeralKey)", forHTTPHeaderField: "Authorization")

		return request
	}
}
