package com.aline.jier.jier

import android.util.Base64
import com.aline.esa.crypto.SecureMessageCipher
import java.nio.charset.StandardCharsets
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

class VaultCipher(
    private val secureRandom: SecureRandom = SecureRandom(),
    private val legacyCipher: SecureMessageCipher = SecureMessageCipher()
) {
    fun encrypt(payload: String, passphrase: String): String {
        require(payload.isNotBlank()) { "原文不能为空。" }
        require(passphrase.isNotBlank()) { "口令不能为空。" }

        val salt = ByteArray(SALT_LENGTH).also(secureRandom::nextBytes)
        val iv = ByteArray(IV_LENGTH).also(secureRandom::nextBytes)
        val key = deriveKey(passphrase, salt)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        val encrypted = cipher.doFinal(payload.toByteArray(StandardCharsets.UTF_8))
        val packed = ByteArray(salt.size + iv.size + encrypted.size)
        salt.copyInto(packed, 0)
        iv.copyInto(packed, salt.size)
        encrypted.copyInto(packed, salt.size + iv.size)
        return PREFIX + Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    fun decrypt(cipherText: String, passphrase: String): String {
        require(cipherText.isNotBlank()) { "密文不能为空。" }
        require(passphrase.isNotBlank()) { "口令不能为空。" }

        return if (cipherText.startsWith(PREFIX)) {
            decryptStandard(cipherText.removePrefix(PREFIX), passphrase)
        } else {
            legacyCipher.decryptFromTraditionalChinese(cipherText, passphrase)
        }
    }

    private fun decryptStandard(encodedPayload: String, passphrase: String): String {
        val packed = Base64.decode(encodedPayload, Base64.NO_WRAP)
        require(packed.size > SALT_LENGTH + IV_LENGTH + MIN_CIPHER_LENGTH) { "密文结构不完整。" }
        val salt = packed.copyOfRange(0, SALT_LENGTH)
        val iv = packed.copyOfRange(SALT_LENGTH, SALT_LENGTH + IV_LENGTH)
        val encrypted = packed.copyOfRange(SALT_LENGTH + IV_LENGTH, packed.size)
        val key = deriveKey(passphrase, salt)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH_BITS, iv))
        return String(cipher.doFinal(encrypted), StandardCharsets.UTF_8)
    }

    private fun deriveKey(passphrase: String, salt: ByteArray): SecretKeySpec {
        val factory = runCatching {
            SecretKeyFactory.getInstance(PBKDF2_SHA256)
        }.getOrElse {
            SecretKeyFactory.getInstance(PBKDF2_SHA1)
        }
        val spec = PBEKeySpec(passphrase.toCharArray(), salt, PBKDF2_ITERATIONS, KEY_LENGTH_BITS)
        return SecretKeySpec(factory.generateSecret(spec).encoded, KEY_ALGORITHM)
    }

    private companion object {
        const val PREFIX = "cx2:"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val KEY_ALGORITHM = "AES"
        const val PBKDF2_SHA256 = "PBKDF2WithHmacSHA256"
        const val PBKDF2_SHA1 = "PBKDF2WithHmacSHA1"
        const val PBKDF2_ITERATIONS = 210_000
        const val KEY_LENGTH_BITS = 256
        const val GCM_TAG_LENGTH_BITS = 128
        const val SALT_LENGTH = 16
        const val IV_LENGTH = 12
        const val MIN_CIPHER_LENGTH = 16
    }
}
