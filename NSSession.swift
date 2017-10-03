//
//  NSSession.swift
//
//  * Supporting swift version 3.1 and 4 *
//
//  - This class is a wrapper of native URLSession APIs for REST based web-services.
//  - Cancel tasks.
//  - Retry-policy.
//  - Multipart form-data.
//
//  - Copyright (c) 2017 Utkarsh Singh. All rights reserved.
//

import Foundation
import UIKit.UIImage

// Configure your base URL.
let BaseURL = "<ADD-YOUR-BASE-URL-HERE>"

public enum HTTPMethod: String {
    case get     = "GET"
    case post    = "POST"
    case put     = "PUT"
    case patch   = "PATCH"
    case delete  = "DELETE"
}

public enum HTTPStatusCode:Int {
    case success = 200
    case created = 201
    case redirectionError = 301
    case badRequest = 400
    case unauthorized = 401
    case forbidden = 403
    case notFound = 404
    case internalServerError = 500
    case methodNotImplemented = 501
    case gatewayTimeOut = 503
}

public enum NSSessionSystemCode:Int {
    case requestTimeout = -1001
    case internetOffline = -1009
    case unableToConnect = -1004
}

public typealias HTTPParameters = [String: Any]

private let kNSSessionErrorDomain = Bundle.main.bundleIdentifier!


class NSSession: NSObject {
    
    static let shared: NSSession = {
        
        var instance = NSSession()
        
        let urlconfig = URLSessionConfiguration.default
        urlconfig.timeoutIntervalForRequest = 45
        urlconfig.timeoutIntervalForResource = 60
        instance.urlSession = Foundation.URLSession(configuration: urlconfig, delegate: nil, delegateQueue: OperationQueue.main)
        
        URLCache.shared.removeAllCachedResponses()
        
        return instance
    }()
    
    private var defaultFatalCodes: [HTTPStatusCode] {
        get {
            return [.badRequest, .internalServerError, .methodNotImplemented, .notFound, .unauthorized, .forbidden]
        }
    }
    
    private var urlSession: URLSession!
    
    private lazy var formDataQueue: OperationQueue = {
        var queue = OperationQueue()
        queue.name = "Form data generator queue"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    
    
    // MARK: Public
    public func requestWith(path: String, method: HTTPMethod, parameters: HTTPParameters?, retryCount:Int, shouldCacheResponse: Bool = false, completionHandler: @escaping(Bool, Data?, Error?) -> Void) -> Void {
        
        let request = enqueueRequestWith(path: path, method: method, parameters: parameters, cacheResponse: shouldCacheResponse)
        
        enqueueDataTaskWith(request: request, retryCount: retryCount) { (data, response, error) in
            self.handle(data: data, response: response, error: error, completionHandler: { (success, data, error) in
                completionHandler(success, data, error)
            })
        }
    }
    
    public func multipartRequestWith(path: String, method: HTTPMethod, parameters: HTTPParameters?, images:[String: UIImage]?, retryCount:Int, completionHandler: @escaping(Bool, Data?, Error?) -> Void) -> Void {
        
        let baseURL = URL(string: BaseURL)
        let relativeURL = URL(fileURLWithPath: path, relativeTo: baseURL)
        
        let boundary = "Boundary-\(UUID().uuidString)"
        
        var request = URLRequest(url: relativeURL)
        request.httpMethod = method.rawValue
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        createMultipartFormData(boundary: boundary, parameters: parameters, images: images) { (data) in
            self.enqueueUploadTaskWith(request: request, data: data, retryCount: retryCount) { (data, response, error) in
                self.handle(data: data, response: response, error: error, completionHandler: { (success, data, error) in
                    completionHandler(success, data, error)
                })
            }
        }
    }
    
    public func cancelAllRequests() -> Void {
        urlSession.getAllTasks { (tasks) in
            for task in tasks {
                task.cancel()
            }
        }
    }
    
    public func cancelRequestWith(path: String) -> Void {
        urlSession.getAllTasks { (tasks) in
            for task in tasks {
                if let absoluteURL = task.originalRequest?.url?.absoluteString {
                    if absoluteURL.contains(path) {task.cancel(); break}
                }
            }
        }
    }
    
    // MARK: Private
    private func enqueueDataTaskWith(request: URLRequest, retryCount:Int, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> Void {
        
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        let task = urlSession.dataTask(with: request, completionHandler: { data, response, error in
            
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            guard error == nil else {
                if let code = NSSessionSystemCode(rawValue: (error! as NSError).code) {
                    completionHandler(nil, nil, NSError.errorWith(code: code.rawValue, localizedDescription: error!.localizedDescription))
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if let code = HTTPStatusCode(rawValue: httpResponse.statusCode) {
                    if retryCount > 0, !(self.defaultFatalCodes.contains(code)), code != .success, code != .created {
                        self.enqueueDataTaskWith(request: request, retryCount: retryCount-1, completionHandler: completionHandler)
                    }
                    else {
                        completionHandler(data, response, error)
                    }
                }
                else {
                    completionHandler(data, response, error)
                }
            }
        })
        
        task.resume()
    }
    
    private func enqueueUploadTaskWith(request: URLRequest, data:Data, retryCount:Int, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> Void {
        
        UIApplication.shared.isNetworkActivityIndicatorVisible = true
        let uploadTask = urlSession.uploadTask(with: request, from: data) { (responseData, response, error) in
            
            UIApplication.shared.isNetworkActivityIndicatorVisible = false
            guard error == nil else {
                if let code = NSSessionSystemCode(rawValue: (error! as NSError).code) {
                    completionHandler(nil, nil, NSError.errorWith(code: code.rawValue, localizedDescription: error!.localizedDescription))
                }
                return
            }
            
            if let httpResponse = response as? HTTPURLResponse {
                if let code = HTTPStatusCode(rawValue: httpResponse.statusCode) {
                    if retryCount > 0, !(self.defaultFatalCodes.contains(code)), code != .success, code != .created {
                        self.enqueueUploadTaskWith(request: request, data: data, retryCount: retryCount-1, completionHandler: completionHandler)
                    }
                    else {
                        completionHandler(responseData, response, error)
                    }
                }
                else {
                    completionHandler(responseData, response, error)
                }
            }
        }
        
        uploadTask.resume()
    }
    
    private func handle(data: Data?, response:URLResponse?, error:Error?, completionHandler: @escaping (Bool, Data?, Error?) -> Void) -> Void {
        
        if let httpResponse = response as? HTTPURLResponse {
            print("Validating request: \(String(describing: response?.url?.absoluteString)) with HTTP status code: \(httpResponse.statusCode)")
            
            let validated = self.validate(response: httpResponse)
            if !validated {
                completionHandler(validated, nil, nil)
                return
            }
            
            if httpResponse.statusCode == HTTPStatusCode.unauthorized.rawValue {
                print("unauthorized access")
                return
            }
        }
        
        guard error == nil else {
            completionHandler(false, nil, error)
            return
        }
        
        guard let data = data else {
            completionHandler(false, nil, nil)
            return
        }
        
        completionHandler(true, data, nil)
    }
    
    // MARK: URLRequest
    private func enqueueRequestWith(path: String, method: HTTPMethod, parameters: HTTPParameters?, cacheResponse: Bool) -> URLRequest {
        
        let baseURL = URL(string: BaseURL)
        let relativeURL = URL(fileURLWithPath: path, relativeTo: baseURL)
        
        var request = URLRequest(url: relativeURL)
        request.httpMethod = method.rawValue
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        
        // Caching response
        if cacheResponse {
            request.cachePolicy = .returnCacheDataElseLoad
        }
        
        switch method {
        case .post:
            if let data = JSONEncode(url: relativeURL, parameters: parameters) {
                request.httpBody = data
            }
            
        case .get:
            if let encodedURL = URLEncode(url: relativeURL, parameters: parameters) {
                request.url = encodedURL
            }
            
        default:
            if let data = JSONEncode(url: relativeURL, parameters: parameters) {
                request.httpBody = data
            }
        }
        
        return request
    }
    
    private func createMultipartFormData(boundary: String, parameters: HTTPParameters?, images: [String: UIImage]?, completionHandler: @escaping (Data) -> Void) -> Void {
        
        let blockOperation = BlockOperation {
            
            var formData = Data()
            
            if parameters != nil, parameters!.count > 0 {
                for (key, element) in parameters! {
                    formData.append("--\(boundary)\r\n".data(using: .utf8)!)
                    formData.append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".data(using: .utf8)!)
                    formData.append("\(element)\r\n".data(using: .utf8)!)
                }
            }
            
            if images != nil, images!.count > 0 {
                
                for (key, value) in images! {
                    
                    let imageData = UIImageJPEGRepresentation(value, 0.5)
                    
                    formData.append("--\(boundary)\r\n".data(using: .utf8)!)
                    formData.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(key).jpeg\"\r\n".data(using: .utf8)!)
                    formData.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
                    formData.append(imageData!)
                    formData.append("\r\n".data(using: .utf8)!)
                }
            }
            
            formData.append("--\(boundary)--\r\n".data(using: .utf8)!)
            
            OperationQueue.main.addOperation {
                completionHandler(formData)
            }
        }
        
        formDataQueue.addOperation(blockOperation)
    }
    
    // MARK: Encoding
    private func encode(url: String) -> String {
        return url.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed)!
    }
    
    private func JSONEncode(url: URL, parameters: HTTPParameters?) -> Data? {
        
        guard parameters != nil else {
            return nil
        }
        
        guard !parameters!.isEmpty else {
            return nil
        }
        
        return query(parameters!).data(using: .utf8, allowLossyConversion: false)!
    }
    
    private func URLEncode(url: URL, parameters: HTTPParameters?) -> URL? {
        
        guard parameters != nil else {
            return nil
        }
        
        guard !parameters!.isEmpty else {
            return nil
        }
        
        if var urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false), !parameters!.isEmpty {
            let percentEncodedQuery = (urlComponents.percentEncodedQuery.map { $0 + "&" } ?? "") + query(parameters!)
            urlComponents.percentEncodedQuery = percentEncodedQuery
            return urlComponents.url
        }
        
        return nil
    }
    
    private func query(_ parameters: HTTPParameters) -> String {
        
        var components: [(String, String)] = []
        
        for key in parameters.keys.sorted(by: <) {
            let value = parameters[key]!
            components += queryComponents(fromKey: key, value: value)
        }
        
        return components.map { "\($0)=\($1)" }.joined(separator: "&")
    }
    
    private func queryComponents(fromKey key: String, value: Any) -> [(String, String)] {
        
        var components: [(String, String)] = []
        
        if let dictionary = value as? [String: Any] {
            for (nestedKey, value) in dictionary {
                components += queryComponents(fromKey: "\(key)[\(nestedKey)]", value: value)
            }
        }
        else if let array = value as? [Any] {
            for value in array {
                components += queryComponents(fromKey: "\(key)[]", value: value)
            }
        }
        else if let value = value as? NSNumber {
            if value.isBoolean {
                components.append((escape(key), escape((value.boolValue ? "1" : "0"))))
            }
            else {
                components.append((escape(key), escape("\(value)")))
            }
        }
        else if let bool = value as? Bool {
            components.append((escape(key), escape((bool ? "1" : "0"))))
        }
        else {
            components.append((escape(key), escape("\(value)")))
        }
        
        return components
    }
    
    private func escape(_ string: String) -> String {
        
        let generalDelimitersToEncode = ":#[]@"
        let subDelimitersToEncode = "!$&'()*+,;="
        
        var allowedCharacterSet = CharacterSet.urlQueryAllowed
        allowedCharacterSet.remove(charactersIn: "\(generalDelimitersToEncode)\(subDelimitersToEncode)")
        
        return string.addingPercentEncoding(withAllowedCharacters: allowedCharacterSet) ?? string
    }
    
    // MARK: Validate
    private func validate(response: HTTPURLResponse) -> Bool {
        if let contentType = response.allHeaderFields["Content-Type"] as? String, contentType.contains("application/json") {
            return true
        }
        
        return false
    }
    
}

extension NSNumber {
    fileprivate var isBoolean: Bool { return CFBooleanGetTypeID() == CFGetTypeID(self) }
}

extension NSError {
    static func errorWith(code: Int, localizedDescription: String?) -> NSError {
        return NSError(domain:kNSSessionErrorDomain, code:code, userInfo:[NSLocalizedDescriptionKey: localizedDescription != nil ? localizedDescription! : ""])
    }
}
