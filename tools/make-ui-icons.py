#!/usr/bin/env python3
# 从 icons/PACKAGE_ICON_256.PNG 派生 DSM 主菜单图标 ui/images/zeronews-{16,24,32,48,64,72,256}.png
#
# DSM 主菜单图标的文件名必须匹配 config 里的 "images/zeronews-{0}.png" 模板，
# {0} 会被依次替换为 16/24/32/48/64/72/256。这里用纯 Python 做 PNG 解码/解码，
# 以免依赖 ImageMagick 或 Pillow。
#
# 用法：python3 synology/tools/make-ui-icons.py

import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SYNO = os.path.dirname(HERE)
SRC = os.path.join(SYNO, "icons", "PACKAGE_ICON_256.PNG")
OUT_DIR = os.path.join(SYNO, "ui", "images")
SIZES = [16, 24, 32, 48, 64, 72, 256]


def read_png(path):
    """读取 8bit RGBA、非隔行 PNG，返回 (width, height, bytearray RGBA)。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("不是 PNG 文件：%s" % path)

    pos = 8
    width = height = bitdepth = colortype = interlace = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length  # 长度+类型+数据+CRC
        if ctype == b"IHDR":
            width, height, bitdepth, colortype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif ctype == b"IDAT":
            idat += body
        elif ctype == b"IEND":
            break

    if bitdepth != 8 or colortype != 6 or interlace != 0:
        raise SystemExit("只支持 8bit RGBA 非隔行 PNG（当前 depth=%s type=%s interlace=%s）"
                         % (bitdepth, colortype, interlace))

    raw = zlib.decompress(bytes(idat))
    bpp = 4
    stride = width * bpp
    out = bytearray(width * height * bpp)
    prev = bytearray(stride)
    p = 0
    for y in range(height):
        ftype = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ftype == 1:      # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:    # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:    # Average
            for i in range(stride):
                left = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:    # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        elif ftype != 0:
            raise SystemExit("未知的 PNG 行过滤器：%s" % ftype)
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, out


def area_scale(src, sw, sh, dw, dh):
    """区域平均缩放（盒式重采样），RGBA 预乘处理以避免边缘发黑。"""
    dst = bytearray(dw * dh * 4)
    for dy in range(dh):
        y0 = dy * sh / dh
        y1 = (dy + 1) * sh / dh
        for dx in range(dw):
            x0 = dx * sw / dw
            x1 = (dx + 1) * sw / dw
            r = g = b = a = 0.0
            weight = 0.0
            iy = int(y0)
            while iy < y1:
                fx = min(y1, iy + 1) - max(y0, iy)
                ix = int(x0)
                while ix < x1:
                    fy = min(x1, ix + 1) - max(x0, ix)
                    w = fx * fy
                    o = (iy * sw + ix) * 4
                    sa = src[o + 3] / 255.0
                    r += src[o] * sa * w
                    g += src[o + 1] * sa * w
                    b += src[o + 2] * sa * w
                    a += src[o + 3] * w
                    weight += w
                    ix += 1
                iy += 1
            o = (dy * dw + dx) * 4
            if weight == 0:
                continue
            a_out = a / weight
            if a_out <= 0:
                dst[o:o + 4] = b"\x00\x00\x00\x00"
            else:
                # 反预乘
                dst[o] = min(255, int(round(r / weight / (a_out / 255.0))))
                dst[o + 1] = min(255, int(round(g / weight / (a_out / 255.0))))
                dst[o + 2] = min(255, int(round(b / weight / (a_out / 255.0))))
                dst[o + 3] = min(255, int(round(a_out)))
    return dst


def write_png(path, width, height, rgba):
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # 过滤器 None
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(ctype, body):
        return (struct.pack(">I", len(body)) + ctype + body
                + struct.pack(">I", zlib.crc32(ctype + body) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def main():
    sw, sh, src = read_png(SRC)
    os.makedirs(OUT_DIR, exist_ok=True)
    for size in SIZES:
        if size == sw:
            write_png(os.path.join(OUT_DIR, "zeronews-%d.png" % size), sw, sh, src)
        else:
            scaled = area_scale(src, sw, sh, size, size)
            write_png(os.path.join(OUT_DIR, "zeronews-%d.png" % size), size, size, scaled)
        print("生成 zeronews-%d.png" % size)


if __name__ == "__main__":
    main()
