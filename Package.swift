// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KaraokeMaker",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // ONNX Runtime 1.19.2 (universal, minos 11) — dylib đóng gói sẵn, offline.
        .binaryTarget(
            name: "onnxruntime",
            path: "vendor/onnxruntime.xcframework"
        ),
        // Cầu C ↔ ONNX Runtime cho MDX-Net (tách giọng nhanh).
        .target(
            name: "MDXOnnx",
            dependencies: ["onnxruntime"],
            path: "Sources/MDXOnnx",
            sources: ["shim.cpp"],
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ]
        ),
        // Bắt NSException (CoreText hiccup lúc vẽ) để app không văng vì 1 khung lỗi.
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "KaraokeMaker",
            dependencies: ["MDXOnnx", "ObjCSupport"],
            path: "Sources/KaraokeMaker",
            resources: [
                .copy("Resources/UVR-MDX-NET-Voc_FT.onnx"),       // MDX-Net (tách nhanh) — 1 kênh
                .copy("Resources/mdx23c-vocinst.onnx"),           // MDX23C (tách chất lượng, fp16) — 2 kênh
                .copy("Resources/mms-aligner-uint8.onnx"),        // MMS forced aligner — canh & ĐI TÌM đoạn lời trong bài (uint8, CPU)
                .copy("Resources/lyric_asr")                      // helper Python "Tự động lấy lời" (qwen-asr) — chạy ở tiến trình riêng
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
)
