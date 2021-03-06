/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

/// Represents an `Operation` encapsulating an HTTP request that uploads a
/// ping to the server. This implements the recommended pieces for execution
/// on a concurrent queue per the documentation for the `Operation` class
/// found [here](https://developer.apple.com/documentation/foundation/operation)
class PingUploadOperation: GleanOperation {
    var uploadTask: URLSessionUploadTask?
    let request: URLRequest
    let data: Data?
    let callback: (Bool, Error?) -> Void

    var backgroundTaskId = UIBackgroundTaskIdentifier.invalid

    /// Create a new PingUploadOperation
    ///
    /// - parameters:
    ///     * request: The `URLRequest` used to upload the ping to the server
    ///     * callback: The callback that the underlying data task returns results through
    init(request: URLRequest, data: Data?, callback: @escaping (Bool, Error?) -> Void) {
        self.request = request
        self.data = data
        self.callback = callback
    }

    /// Handles cancelling the underlying data task
    public override func cancel() {
        uploadTask?.cancel()
        super.cancel()
    }

    /// Starts the data task to upload the ping to the server
    override func start() {
        if self.isCancelled {
            finish(true)
            return
        }

        // Build a URLSession with no-caching suitable for uploading our pings
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = NSURLRequest.CachePolicy.reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)

        // This asks the OS for more time when going to background in order to allow for background
        // uploading of the pings.
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "Glean Upload Task") {
            // End the task if time expires
            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
            self.backgroundTaskId = .invalid
        }

        // Create an URLSessionUploadTask to upload our ping in the background and handle the
        // server responses.
        uploadTask = session.uploadTask(with: request, from: data) { _, response, error in
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            switch statusCode {
            case 200 ..< 300:
                // Known success errors (2xx):
                // 200 - OK. Request accepted into the pipeline.

                // We treat all success codes as successful upload even though we only expect 200.
                self.callback(true, nil)
            case 400 ..< 500:
                // Known client (4xx) errors:
                // 404 - not found - POST/PUT to an unknown namespace
                // 405 - wrong request type (anything other than POST/PUT)
                // 411 - missing content-length header
                // 413 - request body too large (Note that if we have badly-behaved clients that
                //       retry on 4XX, we should send back 202 on body/path too long).
                // 414 - request path too long (See above)

                // Something our client did is not correct. It's unlikely that the client is going
                // to recover from this by re-trying again, so we just log an error and report a
                // successful upload to the service.
                self.callback(true, error)
            default:
                // Known other errors:
                // 500 - internal error

                // For all other errors we log a warning and try again at a later time.
                self.callback(false, error)
            }

            self.executing(false)
            self.finish(true)

            // End background task assertion to let the OS know we are done with our tasks
            UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
            self.backgroundTaskId = UIBackgroundTaskIdentifier.invalid
        }

        executing(true)
        main()
    }

    override func main() {
        uploadTask?.resume()
    }
}
