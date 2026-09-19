import Foundation

/// Once per launch: ask GitHub for the latest release and compare its tag
/// with our version. Silent on any error. The only network request the app
/// ever makes.
final class UpdateChecker {
    struct Update {
        let version: String
        let url: URL
    }

    static let repository = "obsiidi/thock"
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func check(completion: @escaping (Update?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("thock/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else {
                completion(nil)
                return
            }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            completion(isNewer(latest, than: currentVersion) ? Update(version: latest, url: page) : nil)
        }.resume()
    }

    /// Numeric dotted comparison: "0.10.0" > "0.9.1".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
