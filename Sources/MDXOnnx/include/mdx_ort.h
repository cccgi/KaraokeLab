#ifndef MDX_ORT_H
#define MDX_ORT_H

/* Cầu C mỏng cho ONNX Runtime — chạy 1 model MDX-Net (tách giọng nhanh) offline.
   Phần STFT / chia khối / ISTFT làm bên Swift; ở đây chỉ "nạp model" + "chạy tensor". */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MdxSession MdxSession;

/* Nạp model .onnx. `use_coreml` != 0 → thử EP CoreML (Apple Silicon nhanh hơn), lỗi thì CPU.
   Trả NULL nếu hỏng. */
MdxSession *mdx_open(const char *model_path, int use_coreml);
void mdx_close(MdxSession *s);

/* Chạy 1 lần. Vào: tensor float32 `in_data` (in_len phần tử) hình `in_shape[in_rank]`.
   Ra: `out_data` (bên gọi cấp phát `out_capacity` float) — điền, đặt `*out_len`,
   `*out_rank` và `out_shape[8]`.
   0 OK · 2 ngoại lệ · 4 out_capacity nhỏ quá. */
int mdx_run(MdxSession *s,
            const float *in_data, long in_len, const long *in_shape, int in_rank,
            float *out_data, long out_capacity, long *out_len,
            long *out_shape, int *out_rank);

#ifdef __cplusplus
}
#endif

#endif
