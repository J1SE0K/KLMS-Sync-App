import Foundation

extension KeyedDecodingContainer {
    func decodeIfPresentDefault<T: Decodable>(_ type: T.Type, forKey key: Key, default defaultValue: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? defaultValue
    }
}

public enum JSONFileLoader {
    public static func load<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    public static func loadIfExists<T: Decodable>(_ type: T.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try? load(type, from: url, decoder: decoder)
    }
}
