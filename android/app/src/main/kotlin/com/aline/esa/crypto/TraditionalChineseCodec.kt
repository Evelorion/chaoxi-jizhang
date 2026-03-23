package com.aline.esa.crypto

import java.util.Base64

object TraditionalChineseCodec {
    private const val STANDARD_ALPHABET =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    private const val TRADITIONAL_ALPHABET =
        "天地玄黃宇宙洪荒日月盈昃辰宿列張寒來暑往秋收冬藏閏餘成歲律呂調陽雲騰致雨露結為霜金生麗水玉出崑岡劍號巨闕珠稱夜光果珍李柰菜重芥薑"

    private val encodeMap = STANDARD_ALPHABET.toList().zip(TRADITIONAL_ALPHABET.toList()).toMap()
    private val decodeMap = encodeMap.entries.associate { (latin, han) -> han to latin }

    fun encode(bytes: ByteArray): String {
        val base64 = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
        return buildString(base64.length) {
            base64.forEach { symbol ->
                append(encodeMap[symbol] ?: error("无法编码字符: $symbol"))
            }
        }
    }

    fun decode(traditionalText: String): ByteArray {
        val compact = traditionalText.filterNot(Char::isWhitespace)
        require(compact.isNotEmpty()) { "密文不能为空。" }
        val standard = buildString(compact.length) {
            compact.forEach { symbol ->
                append(decodeMap[symbol] ?: throw IllegalArgumentException("发现非法繁体密文字元：$symbol"))
            }
        }
        val padded = standard.padEnd((standard.length + 3) / 4 * 4, '=')
        return Base64.getUrlDecoder().decode(padded)
    }

    fun alphabet(): String = TRADITIONAL_ALPHABET
}
