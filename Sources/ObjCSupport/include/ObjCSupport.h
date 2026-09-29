#import <Foundation/Foundation.h>

/// Chạy `block`; nếu nó ném NSException (vd CoreText hiccup lúc vẽ chữ) thì NUỐT lại
/// và trả về NO — để app KHÔNG văng vì 1 khung hình lỗi. Swift không bắt được NSException.
BOOL kmk_tryCatch(void (NS_NOESCAPE ^ _Nonnull block)(void));
