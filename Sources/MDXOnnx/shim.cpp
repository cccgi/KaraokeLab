// Cầu C ↔ ONNX Runtime cho model MDX-Net / MMS aligner.
#include "mdx_ort.h"

#include <onnxruntime_cxx_api.h>
#include <coreml_provider_factory.h>

#include <cstdio>
#include <string>
#include <vector>

struct MdxSession {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "mdx"};
    Ort::Session session{nullptr};
    Ort::AllocatorWithDefaultOptions alloc;
    std::string in_name;
    std::string out_name;
};

static Ort::Session make_session(Ort::Env &env, const char *path, bool coreml)
{
    Ort::SessionOptions opt;
    opt.SetIntraOpNumThreads(0);
    opt.SetGraphOptimizationLevel(ORT_ENABLE_ALL);
    if (coreml) {
        uint32_t flags = 0;
        Ort::ThrowOnError(OrtSessionOptionsAppendExecutionProvider_CoreML(opt, flags));
    }
    return Ort::Session(env, path, opt);
}

extern "C" MdxSession *mdx_open(const char *model_path, int use_coreml)
{
    if (!model_path) return nullptr;
    auto *s = new MdxSession();
    bool ok = false;

    if (use_coreml) {
        try {
            s->session = make_session(s->env, model_path, true);
            ok = true;
        } catch (const std::exception &e) {
            std::fprintf(stderr, "[mdx_ort] CoreML EP thất bại, thử CPU: %s\n", e.what());
        } catch (...) {
            std::fprintf(stderr, "[mdx_ort] CoreML EP thất bại (lỗi lạ), thử CPU\n");
        }
    }
    if (!ok) {
        try {
            s->session = make_session(s->env, model_path, false);
            ok = true;
        } catch (const std::exception &e) {
            std::fprintf(stderr, "[mdx_ort] mở model lỗi (CPU): %s\n", e.what());
        } catch (...) {
            std::fprintf(stderr, "[mdx_ort] mở model lỗi (CPU, lỗi lạ)\n");
        }
    }
    if (!ok) { delete s; return nullptr; }

    try {
        auto in0 = s->session.GetInputNameAllocated(0, s->alloc);
        auto out0 = s->session.GetOutputNameAllocated(0, s->alloc);
        s->in_name = in0.get();
        s->out_name = out0.get();
        return s;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "[mdx_ort] đọc tên in/out lỗi: %s\n", e.what());
        delete s;
        return nullptr;
    }
}

extern "C" void mdx_close(MdxSession *s) { delete s; }

extern "C" int mdx_run(MdxSession *s,
                       const float *in_data, long in_len,
                       const long *in_shape, int in_rank,
                       float *out_data, long out_capacity, long *out_len,
                       long *out_shape, int *out_rank)
{
    if (!s || !in_data || !out_data || in_rank <= 0) return 2;
    try {
        std::vector<int64_t> shp;
        shp.reserve(in_rank);
        for (int i = 0; i < in_rank; ++i) shp.push_back((int64_t)in_shape[i]);

        Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        Ort::Value input = Ort::Value::CreateTensor<float>(
            mem, const_cast<float *>(in_data), (size_t)in_len, shp.data(), shp.size());

        const char *inNames[] = {s->in_name.c_str()};
        const char *outNames[] = {s->out_name.c_str()};

        auto outs = s->session.Run(Ort::RunOptions{nullptr},
                                   inNames, &input, 1, outNames, 1);

        Ort::Value &o = outs[0];
        auto info = o.GetTensorTypeAndShapeInfo();
        std::vector<int64_t> oshape = info.GetShape();
        size_t total = info.GetElementCount();
        if ((long)total > out_capacity) return 4;

        const float *od = o.GetTensorData<float>();
        for (size_t i = 0; i < total; ++i) out_data[i] = od[i];

        *out_len = (long)total;
        *out_rank = (int)oshape.size();
        for (size_t i = 0; i < oshape.size() && i < 8; ++i)
            out_shape[i] = (long)oshape[i];
        return 0;
    } catch (...) {
        return 2;
    }
}
