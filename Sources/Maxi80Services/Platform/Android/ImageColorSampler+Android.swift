import Foundation

#if !SKIP_BRIDGE

#if SKIP
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color

// MARK: - Android sampling
//
// Decode the bytes, downscale to 40×40, read the pixels, average — mirroring the Apple path so
// the live background color matches across platforms for the same artwork.

extension ImageColorSampler {

    func averagedComponents(from data: Data) -> (red: Double, green: Double, blue: Double)? {
        // `data.platformValue` is the underlying kotlin.ByteArray (SkipFoundation).
        let bytes = data.platformValue
        guard let bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) else { return nil }

        let size = 40
        let scaled = Bitmap.createScaledBitmap(bitmap, size, size, false)

        let pixelCount = size * size
        let pixels = IntArray(pixelCount)
        scaled.getPixels(pixels, 0, size, 0, 0, size, size)

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0

        for i in 0..<pixelCount {
            let pixel = pixels[i]
            totalR += Double(Color.red(pixel))
            totalG += Double(Color.green(pixel))
            totalB += Double(Color.blue(pixel))
        }

        return (
            red: totalR / Double(pixelCount) / 255.0,
            green: totalG / Double(pixelCount) / 255.0,
            blue: totalB / Double(pixelCount) / 255.0
        )
    }
}
#endif // SKIP

#endif // !SKIP_BRIDGE
