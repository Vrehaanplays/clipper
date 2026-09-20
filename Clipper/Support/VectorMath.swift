import Accelerate
import Foundation

/// Float vectors, stored as raw bytes and compared with Accelerate.
///
/// Used for two different things: speaker centroids (log-mel feature means) and semantic
/// search (`NLEmbedding` sentence vectors). Both want the same three operations, so they
/// share one implementation.
enum VectorMath {
    /// Pack to little-endian float32 bytes. Stable across launches and devices.
    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data?) -> [Float] {
        guard let data, !data.isEmpty else { return [] }
        let count = data.count / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var vector = [Float](repeating: 0, count: count)
        _ = vector.withUnsafeMutableBytes { destination in
            data.copyBytes(to: destination, count: count * MemoryLayout<Float>.size)
        }
        return vector
    }

    /// Cosine similarity, -1...1. Returns 0 for mismatched or empty vectors rather than
    /// throwing: a missing embedding means "no semantic opinion", not an error.
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        var dot: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 1e-9 else { return 0 }
        return Double(dot / denominator)
    }

    /// Incremental mean, so a speaker centroid can absorb a new sample without keeping
    /// every past sample around.
    static func runningMean(current: [Float], count: Int, adding sample: [Float]) -> [Float] {
        guard !sample.isEmpty else { return current }
        guard !current.isEmpty, current.count == sample.count, count > 0 else { return sample }
        let weight = Float(count)
        var result = [Float](repeating: 0, count: current.count)
        for i in 0..<current.count {
            result[i] = (current[i] * weight + sample[i]) / (weight + 1)
        }
        return result
    }

    /// L2-normalise in place. Comparing normalised vectors turns cosine into a dot product.
    static func normalized(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumOfSquares)
        guard norm > 1e-9 else { return vector }
        var divisor = norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }
}
