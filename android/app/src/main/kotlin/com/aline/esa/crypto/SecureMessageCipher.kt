package com.aline.esa.crypto

import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer

class SecureMessageCipher(
    private val secureRandom: SecureRandom = SecureRandom()
) {
    fun encryptToTraditionalChinese(plainText: String, passphrase: String): String {
        validatePlainText(plainText)
        return encryptV5(plainText, passphrase)
    }

    fun decryptFromTraditionalChinese(traditionalCipherText: String, passphrase: String): String {
        validateCipherText(traditionalCipherText)

        val normalizedPassphrase = normalizePassphrase(passphrase)
        val payload = TraditionalChineseCodec.decode(traditionalCipherText)
        require(payload.size > HEADER_LENGTH) { "密文长度异常。" }

        val header = parseHeader(payload.copyOfRange(0, HEADER_LENGTH))
        return when (header.version) {
            VERSION_V4 -> decryptV4(payload, normalizedPassphrase, header)
            VERSION_V5 -> decryptV5(payload, normalizedPassphrase, header)
            else -> throw IllegalArgumentException("不支持的密文版本。")
        }
    }

    internal fun encryptLegacyToTraditionalChineseForTest(
        plainText: String,
        passphrase: String
    ): String {
        validatePlainText(plainText)
        return encryptV4(plainText, passphrase)
    }

    private fun encryptV4(plainText: String, passphrase: String): String {
        val normalizedPassphrase = normalizePassphrase(passphrase)
        val plainBytes = plainText.toByteArray(StandardCharsets.UTF_8)
        val salt = ByteArray(SALT_LENGTH_V4).also(secureRandom::nextBytes)
        val nonce = ByteArray(NONCE_LENGTH_V4).also(secureRandom::nextBytes)
        val context = deriveContextV4(normalizedPassphrase, salt, nonce, DEFAULT_ROUNDS_V4)
        val header = buildHeader(
            version = VERSION_V4,
            rounds = context.rounds,
            saltLength = salt.size,
            nonceLength = nonce.size,
            tagLength = TAG_LENGTH_V4,
            plainLength = plainBytes.size
        )

        return try {
            val padded = pad(plainBytes)
            val cipherBytes = encryptBlocksV4(padded, context, nonce)
            val tag = buildTagV4(header, salt, nonce, cipherBytes, context)
            TraditionalChineseCodec.encode(buildPayload(header, salt, nonce, cipherBytes, tag))
        } finally {
            clearContext(context)
        }
    }

    private fun encryptV5(plainText: String, passphrase: String): String {
        val normalizedPassphrase = normalizePassphrase(passphrase)
        val plainBytes = plainText.toByteArray(StandardCharsets.UTF_8)
        val salt = ByteArray(SALT_LENGTH_V5).also(secureRandom::nextBytes)
        val nonce = ByteArray(NONCE_LENGTH_V5).also(secureRandom::nextBytes)
        val context = deriveContextV5(normalizedPassphrase, salt, nonce, DEFAULT_ROUNDS_V5)
        val header = buildHeader(
            version = VERSION_V5,
            rounds = context.rounds,
            saltLength = salt.size,
            nonceLength = nonce.size,
            tagLength = TAG_LENGTH_V5,
            plainLength = plainBytes.size
        )

        return try {
            val padded = pad(plainBytes)
            val cipherBytes = encryptBlocksV5(padded, context, nonce)
            val tag = buildTagV5(header, salt, nonce, cipherBytes, context)
            TraditionalChineseCodec.encode(buildPayload(header, salt, nonce, cipherBytes, tag))
        } finally {
            clearContext(context)
        }
    }

    private fun decryptV4(payload: ByteArray, passphrase: String, header: PayloadHeader): String {
        validateHeaderV4(header, payload.size)
        val parts = extractPayloadParts(payload, header)
        val context = deriveContextV4(passphrase, parts.salt, parts.nonce, header.rounds)

        return try {
            val expectedTag = buildTagV4(
                header = payload.copyOfRange(0, HEADER_LENGTH),
                salt = parts.salt,
                nonce = parts.nonce,
                cipherBytes = parts.cipherBytes,
                context = context
            )
            require(constantTimeEquals(parts.tag, expectedTag)) { "口令错误，或密文已被篡改。" }
            val paddedPlainBytes = decryptBlocksV4(parts.cipherBytes, context, parts.nonce)
            require(header.plainLength <= paddedPlainBytes.size) { "原文长度与密文不匹配。" }
            String(paddedPlainBytes.copyOf(header.plainLength), StandardCharsets.UTF_8)
        } finally {
            clearContext(context)
        }
    }

    private fun decryptV5(payload: ByteArray, passphrase: String, header: PayloadHeader): String {
        validateHeaderV5(header, payload.size)
        val parts = extractPayloadParts(payload, header)
        val context = deriveContextV5(passphrase, parts.salt, parts.nonce, header.rounds)

        return try {
            val expectedTag = buildTagV5(
                header = payload.copyOfRange(0, HEADER_LENGTH),
                salt = parts.salt,
                nonce = parts.nonce,
                cipherBytes = parts.cipherBytes,
                context = context
            )
            require(constantTimeEquals(parts.tag, expectedTag)) { "口令错误，或密文已被篡改。" }
            val paddedPlainBytes = decryptBlocksV5(parts.cipherBytes, context, parts.nonce)
            require(header.plainLength <= paddedPlainBytes.size) { "原文长度与密文不匹配。" }
            String(paddedPlainBytes.copyOf(header.plainLength), StandardCharsets.UTF_8)
        } finally {
            clearContext(context)
        }
    }

    private fun normalizePassphrase(passphrase: String): String =
        Normalizer.normalize(passphrase, Normalizer.Form.NFC)

    private fun parseHeader(headerBytes: ByteArray): PayloadHeader {
        val headerBuffer = ByteBuffer.wrap(headerBytes)
        return PayloadHeader(
            version = headerBuffer.get(),
            rounds = headerBuffer.get().toInt() and 0xFF,
            saltLength = headerBuffer.get().toInt() and 0xFF,
            nonceLength = headerBuffer.get().toInt() and 0xFF,
            tagLength = headerBuffer.get().toInt() and 0xFF,
            plainLength = headerBuffer.int
        )
    }

    private fun validateHeaderV4(header: PayloadHeader, payloadSize: Int) {
        require(header.rounds >= MIN_ROUNDS_V4) { "密文参数不安全或已损坏。" }
        require(header.saltLength >= MIN_SALT_LENGTH_V4) { "盐长度异常。" }
        require(header.nonceLength >= MIN_NONCE_LENGTH_V4) { "随机种长度异常。" }
        require(header.tagLength == TAG_LENGTH_V4) { "校验长度异常。" }
        require(header.plainLength >= 0) { "原文长度异常。" }
        require(payloadSize > HEADER_LENGTH + header.saltLength + header.nonceLength + header.tagLength) {
            "密文结构不完整。"
        }
    }

    private fun validateHeaderV5(header: PayloadHeader, payloadSize: Int) {
        require(header.rounds >= MIN_ROUNDS_V5) { "密文参数不安全或已损坏。" }
        require(header.saltLength >= MIN_SALT_LENGTH_V5) { "盐长度异常。" }
        require(header.nonceLength >= MIN_NONCE_LENGTH_V5) { "随机种长度异常。" }
        require(header.tagLength == TAG_LENGTH_V5) { "校验长度异常。" }
        require(header.plainLength >= 0) { "原文长度异常。" }
        require(payloadSize > HEADER_LENGTH + header.saltLength + header.nonceLength + header.tagLength) {
            "密文结构不完整。"
        }
    }

    private fun extractPayloadParts(payload: ByteArray, header: PayloadHeader): PayloadParts {
        val buffer = ByteBuffer.wrap(payload)
        buffer.position(HEADER_LENGTH)
        val salt = ByteArray(header.saltLength).also(buffer::get)
        val nonce = ByteArray(header.nonceLength).also(buffer::get)
        val cipherLength = payload.size - HEADER_LENGTH - header.saltLength - header.nonceLength - header.tagLength
        require(cipherLength > 0 && cipherLength % BLOCK_SIZE == 0) { "密文块长度异常。" }
        val cipherBytes = ByteArray(cipherLength).also(buffer::get)
        val tag = ByteArray(header.tagLength).also(buffer::get)
        return PayloadParts(salt, nonce, cipherBytes, tag)
    }

    private fun buildPayload(
        header: ByteArray,
        salt: ByteArray,
        nonce: ByteArray,
        cipherBytes: ByteArray,
        tag: ByteArray
    ): ByteArray = ByteBuffer.allocate(header.size + salt.size + nonce.size + cipherBytes.size + tag.size)
        .put(header)
        .put(salt)
        .put(nonce)
        .put(cipherBytes)
        .put(tag)
        .array()
    private fun deriveContextV4(
        passphrase: String,
        salt: ByteArray,
        nonce: ByteArray,
        rounds: Int
    ): CipherContext {
        val passphraseBytes = passphrase.toByteArray(StandardCharsets.UTF_8)
        var masterState = digest512(passphraseBytes + salt + nonce + rounds.toByte())

        repeat(KEY_STRETCH_CYCLES_V4) { cycle ->
            val cycleBytes = byteArrayOf((cycle ushr 8).toByte(), cycle.toByte())
            val mix = if ((cycle and 1) == 0) {
                digest512(masterState + passphraseBytes + salt + cycleBytes)
            } else {
                digest512(passphraseBytes + masterState + nonce + cycleBytes)
            }

            for (index in masterState.indices) {
                val value = (masterState[index].toInt() and 0xFF) xor
                    (mix[index].toInt() and 0xFF) xor
                    ((cycle + index * 13) and 0xFF)
                masterState[index] = value.toByte()
            }

            masterState = digest512(masterState + salt + nonce + cycleBytes)
        }

        val roundKeys = Array(rounds) { round ->
            val material = digest512(masterState + passphraseBytes + salt + nonce + round.toByte())
            material.copyOf(HALF_BLOCK_SIZE)
        }
        val sBox = buildPermutation(masterState + salt + nonce + V4_SBOX_DOMAIN, 256)
        val inverseSBox = buildInversePermutation(sBox)
        val blockPermutation = buildPermutation(masterState + nonce + salt + V4_BLOCK_DOMAIN, BLOCK_SIZE)
        val inverseBlockPermutation = buildInversePermutation(blockPermutation)
        passphraseBytes.fill(0)

        return CipherContext(
            rounds = rounds,
            masterState = masterState,
            roundKeys = roundKeys,
            roundTweaks = Array(rounds) { ByteArray(HALF_BLOCK_SIZE) },
            primarySBox = sBox,
            inversePrimarySBox = inverseSBox,
            secondarySBox = sBox.copyOf(),
            inverseSecondarySBox = inverseSBox.copyOf(),
            entryPermutation = blockPermutation,
            inverseEntryPermutation = inverseBlockPermutation,
            exitPermutation = blockPermutation.copyOf(),
            inverseExitPermutation = inverseBlockPermutation.copyOf(),
            preWhitening = ByteArray(BLOCK_SIZE),
            postWhitening = ByteArray(BLOCK_SIZE)
        )
    }

    private fun deriveContextV5(
        passphrase: String,
        salt: ByteArray,
        nonce: ByteArray,
        rounds: Int
    ): CipherContext {
        val passphraseBytes = passphrase.toByteArray(StandardCharsets.UTF_8)
        var seed = digest512(V5_SEED_DOMAIN + passphraseBytes + salt + nonce + rounds.toByte())
        var accumulator = expandState(V5_STATE_DOMAIN + seed + passphraseBytes + salt + nonce, MASTER_STATE_LENGTH_V5)

        repeat(KEY_STRETCH_CYCLES_V5) { cycle ->
            val cycleBytes = intToBytes(cycle)
            val mixA = digest512(V5_STRETCH_A_DOMAIN + accumulator + seed + salt + cycleBytes)
            val mixB = digest512(V5_STRETCH_B_DOMAIN + passphraseBytes + accumulator + nonce + cycleBytes)

            for (index in accumulator.indices) {
                val current = accumulator[index].toInt() and 0xFF
                val laneA = mixA[index % mixA.size].toInt() and 0xFF
                val laneB = mixB[(index * 5 + cycle) % mixB.size].toInt() and 0xFF
                val saltByte = salt[(index + cycle) % salt.size].toInt() and 0xFF
                accumulator[index] = rotateLeftByte(
                    current xor laneA xor laneB xor saltByte xor ((cycle + index * 17) and 0xFF),
                    ((index + cycle) % 7) + 1
                ).toByte()
            }

            if ((cycle and 63) == 63) {
                accumulator = expandState(
                    V5_RESEED_DOMAIN + accumulator + mixA + mixB + seed,
                    MASTER_STATE_LENGTH_V5
                )
            }

            seed = digest512(seed + mixA + mixB + cycleBytes + V5_SEED_DOMAIN)
        }

        val masterState = expandState(V5_MASTER_DOMAIN + accumulator + seed + salt + nonce, MASTER_STATE_LENGTH_V5)
        val roundKeys = Array(rounds) { round ->
            expandState(V5_ROUND_KEY_DOMAIN + masterState + salt + nonce + intToBytes(round), HALF_BLOCK_SIZE)
        }
        val roundTweaks = Array(rounds) { round ->
            expandState(V5_ROUND_TWEAK_DOMAIN + masterState + nonce + salt + intToBytes(round), HALF_BLOCK_SIZE)
        }
        val primarySBox = buildPermutation(V5_SBOX_A_DOMAIN + masterState + salt + nonce, 256)
        val inversePrimarySBox = buildInversePermutation(primarySBox)
        val secondarySBox = buildPermutation(V5_SBOX_B_DOMAIN + nonce + masterState + salt, 256)
        val inverseSecondarySBox = buildInversePermutation(secondarySBox)
        val entryPermutation = buildPermutation(V5_ENTRY_DOMAIN + masterState + salt + nonce, BLOCK_SIZE)
        val inverseEntryPermutation = buildInversePermutation(entryPermutation)
        val exitPermutation = buildPermutation(V5_EXIT_DOMAIN + nonce + salt + masterState, BLOCK_SIZE)
        val inverseExitPermutation = buildInversePermutation(exitPermutation)
        val preWhitening = expandState(V5_PRE_WHITEN_DOMAIN + masterState + salt, BLOCK_SIZE)
        val postWhitening = expandState(V5_POST_WHITEN_DOMAIN + masterState + nonce, BLOCK_SIZE)
        passphraseBytes.fill(0)
        accumulator.fill(0)
        seed.fill(0)

        return CipherContext(
            rounds = rounds,
            masterState = masterState,
            roundKeys = roundKeys,
            roundTweaks = roundTweaks,
            primarySBox = primarySBox,
            inversePrimarySBox = inversePrimarySBox,
            secondarySBox = secondarySBox,
            inverseSecondarySBox = inverseSecondarySBox,
            entryPermutation = entryPermutation,
            inverseEntryPermutation = inverseEntryPermutation,
            exitPermutation = exitPermutation,
            inverseExitPermutation = inverseExitPermutation,
            preWhitening = preWhitening,
            postWhitening = postWhitening
        )
    }
    private fun encryptBlocksV4(plainBytes: ByteArray, context: CipherContext, nonce: ByteArray): ByteArray {
        val output = ByteArray(plainBytes.size)
        var chainingState = digest512(V4_CHAIN_DOMAIN + nonce + context.masterState).copyOf(BLOCK_SIZE)
        var offset = 0
        var blockIndex = 0

        while (offset < plainBytes.size) {
            val preMask = deriveBlockMask(context.masterState, nonce, blockIndex, V4_PRE_MASK_DOMAIN)
            val postMask = deriveBlockMask(context.masterState, nonce, blockIndex, V4_POST_MASK_DOMAIN)
            val mixedBlock = xorThreeBlocks(plainBytes, offset, chainingState, preMask)
            val substituted = substituteBlock(mixedBlock, context.primarySBox)
            val encryptedCore = feistelEncryptBlockV4(substituted, context, blockIndex)
            val permuted = permuteBlock(encryptedCore, context.entryPermutation)
            val finalBlock = xorTwoBlocks(permuted, postMask)
            finalBlock.copyInto(output, offset)
            chainingState = finalBlock
            offset += BLOCK_SIZE
            blockIndex++
        }

        return output
    }

    private fun decryptBlocksV4(cipherBytes: ByteArray, context: CipherContext, nonce: ByteArray): ByteArray {
        val output = ByteArray(cipherBytes.size)
        var chainingState = digest512(V4_CHAIN_DOMAIN + nonce + context.masterState).copyOf(BLOCK_SIZE)
        var offset = 0
        var blockIndex = 0

        while (offset < cipherBytes.size) {
            val currentCipher = cipherBytes.copyOfRange(offset, offset + BLOCK_SIZE)
            val preMask = deriveBlockMask(context.masterState, nonce, blockIndex, V4_PRE_MASK_DOMAIN)
            val postMask = deriveBlockMask(context.masterState, nonce, blockIndex, V4_POST_MASK_DOMAIN)
            val unmasked = xorTwoBlocks(currentCipher, postMask)
            val inversePermuted = inversePermuteBlock(unmasked, context.inverseEntryPermutation)
            val decryptedCore = feistelDecryptBlockV4(inversePermuted, context, blockIndex)
            val unsubstituted = substituteBlock(decryptedCore, context.inversePrimarySBox)
            val plainBlock = xorThreeBlocks(unsubstituted, chainingState, preMask)
            plainBlock.copyInto(output, offset)
            chainingState = currentCipher
            offset += BLOCK_SIZE
            blockIndex++
        }

        return output
    }

    private fun encryptBlocksV5(plainBytes: ByteArray, context: CipherContext, nonce: ByteArray): ByteArray {
        val output = ByteArray(plainBytes.size)
        var chainingState = initialChainStateV5(context, nonce)
        var offset = 0
        var blockIndex = 0

        while (offset < plainBytes.size) {
            val tweak = deriveBlockMask(context.masterState, nonce, blockIndex, V5_TWEAK_DOMAIN)
            val preMask = deriveBlockMask(context.masterState, nonce, blockIndex, V5_PRE_MASK_DOMAIN)
            val postMask = deriveBlockMask(context.masterState, nonce, blockIndex, V5_POST_MASK_DOMAIN)
            val mixedBlock = xorFourBlocks(plainBytes, offset, chainingState, preMask, context.preWhitening)
            val tweaked = xorTwoBlocks(mixedBlock, tweak)
            val entryPermuted = permuteBlock(tweaked, context.entryPermutation)
            val primarySubstituted = substituteBlock(entryPermuted, context.primarySBox)
            val encryptedCore = feistelEncryptBlockV5(primarySubstituted, context, blockIndex, tweak)
            val secondarySubstituted = substituteBlock(encryptedCore, context.secondarySBox)
            val exitPermuted = permuteBlock(secondarySubstituted, context.exitPermutation)
            val finalBlock = xorFourBlocks(exitPermuted, postMask, context.postWhitening, tweak)
            finalBlock.copyInto(output, offset)
            chainingState = updateChainStateV5(finalBlock, tweak, context.masterState)
            offset += BLOCK_SIZE
            blockIndex++
        }

        return output
    }

    private fun decryptBlocksV5(cipherBytes: ByteArray, context: CipherContext, nonce: ByteArray): ByteArray {
        val output = ByteArray(cipherBytes.size)
        var chainingState = initialChainStateV5(context, nonce)
        var offset = 0
        var blockIndex = 0

        while (offset < cipherBytes.size) {
            val currentCipher = cipherBytes.copyOfRange(offset, offset + BLOCK_SIZE)
            val tweak = deriveBlockMask(context.masterState, nonce, blockIndex, V5_TWEAK_DOMAIN)
            val preMask = deriveBlockMask(context.masterState, nonce, blockIndex, V5_PRE_MASK_DOMAIN)
            val postMask = deriveBlockMask(context.masterState, nonce, blockIndex, V5_POST_MASK_DOMAIN)
            val unmasked = xorFourBlocks(currentCipher, postMask, context.postWhitening, tweak)
            val inverseExitPermuted = inversePermuteBlock(unmasked, context.inverseExitPermutation)
            val inverseSecondary = substituteBlock(inverseExitPermuted, context.inverseSecondarySBox)
            val decryptedCore = feistelDecryptBlockV5(inverseSecondary, context, blockIndex, tweak)
            val inversePrimary = substituteBlock(decryptedCore, context.inversePrimarySBox)
            val inverseEntry = inversePermuteBlock(inversePrimary, context.inverseEntryPermutation)
            val untweaked = xorTwoBlocks(inverseEntry, tweak)
            val plainBlock = xorFourBlocks(untweaked, chainingState, preMask, context.preWhitening)
            plainBlock.copyInto(output, offset)
            chainingState = updateChainStateV5(currentCipher, tweak, context.masterState)
            offset += BLOCK_SIZE
            blockIndex++
        }

        return output
    }

    private fun buildTagV4(
        header: ByteArray,
        salt: ByteArray,
        nonce: ByteArray,
        cipherBytes: ByteArray,
        context: CipherContext
    ): ByteArray {
        val digest = MessageDigest.getInstance(SHA512)
        digest.update(V4_TAG_DOMAIN)
        digest.update(header)
        digest.update(salt)
        digest.update(nonce)
        digest.update(cipherBytes)
        digest.update(context.masterState)
        context.roundKeys.forEach(digest::update)
        return digest.digest().copyOf(TAG_LENGTH_V4)
    }

    private fun buildTagV5(
        header: ByteArray,
        salt: ByteArray,
        nonce: ByteArray,
        cipherBytes: ByteArray,
        context: CipherContext
    ): ByteArray {
        val firstPass = MessageDigest.getInstance(SHA512).run {
            update(V5_TAG_DOMAIN)
            update(header)
            update(salt)
            update(nonce)
            update(cipherBytes)
            update(context.masterState)
            update(context.preWhitening)
            update(context.postWhitening)
            context.roundKeys.forEach(::update)
            context.roundTweaks.forEach(::update)
            digest()
        }

        return digest512(
            V5_TAG_RESEAL_DOMAIN +
                firstPass +
                windowBytes(context.masterState, 11, 48) +
                salt +
                nonce
        ).copyOf(TAG_LENGTH_V5)
    }

    private fun feistelEncryptBlockV4(block: ByteArray, context: CipherContext, blockIndex: Int): ByteArray {
        var left = block.copyOfRange(0, HALF_BLOCK_SIZE)
        var right = block.copyOfRange(HALF_BLOCK_SIZE, BLOCK_SIZE)

        context.roundKeys.forEachIndexed { round, roundKey ->
            val nextLeft = right
            val nextRight = xorHalfBlocks(
                left,
                roundFunctionV4(right, roundKey, round, blockIndex, context.masterState, context.primarySBox)
            )
            left = nextLeft
            right = nextRight
        }

        return left + right
    }

    private fun feistelDecryptBlockV4(block: ByteArray, context: CipherContext, blockIndex: Int): ByteArray {
        var left = block.copyOfRange(0, HALF_BLOCK_SIZE)
        var right = block.copyOfRange(HALF_BLOCK_SIZE, BLOCK_SIZE)

        for (round in context.roundKeys.lastIndex downTo 0) {
            val previousRight = left
            val previousLeft = xorHalfBlocks(
                right,
                roundFunctionV4(
                    previousRight,
                    context.roundKeys[round],
                    round,
                    blockIndex,
                    context.masterState,
                    context.primarySBox
                )
            )
            left = previousLeft
            right = previousRight
        }

        return left + right
    }

    private fun feistelEncryptBlockV5(
        block: ByteArray,
        context: CipherContext,
        blockIndex: Int,
        tweak: ByteArray
    ): ByteArray {
        var left = block.copyOfRange(0, HALF_BLOCK_SIZE)
        var right = block.copyOfRange(HALF_BLOCK_SIZE, BLOCK_SIZE)

        context.roundKeys.forEachIndexed { round, roundKey ->
            val nextLeft = right
            val nextRight = xorHalfBlocks(
                left,
                roundFunctionV5(
                    right = right,
                    roundKey = roundKey,
                    roundTweak = context.roundTweaks[round],
                    round = round,
                    blockIndex = blockIndex,
                    masterState = context.masterState,
                    primarySBox = context.primarySBox,
                    secondarySBox = context.secondarySBox,
                    tweak = tweak
                )
            )
            left = nextLeft
            right = nextRight
        }

        return left + right
    }

    private fun feistelDecryptBlockV5(
        block: ByteArray,
        context: CipherContext,
        blockIndex: Int,
        tweak: ByteArray
    ): ByteArray {
        var left = block.copyOfRange(0, HALF_BLOCK_SIZE)
        var right = block.copyOfRange(HALF_BLOCK_SIZE, BLOCK_SIZE)

        for (round in context.roundKeys.lastIndex downTo 0) {
            val previousRight = left
            val previousLeft = xorHalfBlocks(
                right,
                roundFunctionV5(
                    right = previousRight,
                    roundKey = context.roundKeys[round],
                    roundTweak = context.roundTweaks[round],
                    round = round,
                    blockIndex = blockIndex,
                    masterState = context.masterState,
                    primarySBox = context.primarySBox,
                    secondarySBox = context.secondarySBox,
                    tweak = tweak
                )
            )
            left = previousLeft
            right = previousRight
        }

        return left + right
    }

    private fun roundFunctionV4(
        right: ByteArray,
        roundKey: ByteArray,
        round: Int,
        blockIndex: Int,
        masterState: ByteArray,
        sBox: IntArray
    ): ByteArray {
        val laneSeed = digest256(
            right +
                roundKey +
                intToBytes(round) +
                intToBytes(blockIndex) +
                windowBytes(masterState, (round * 3) % masterState.size, HALF_BLOCK_SIZE)
        )
        val output = ByteArray(HALF_BLOCK_SIZE)

        for (index in 0 until HALF_BLOCK_SIZE) {
            val base = right[index].toInt() and 0xFF
            val key = roundKey[(index + round) % HALF_BLOCK_SIZE].toInt() and 0xFF
            val lane = laneSeed[index].toInt() and 0xFF
            val neighbor = right[(index + 1) % HALF_BLOCK_SIZE].toInt() and 0xFF
            val stateByte = masterState[(round * 11 + blockIndex * 7 + index * 5) % masterState.size].toInt() and 0xFF
            val substituted = sBox[(base xor key xor lane xor stateByte) and 0xFF]
            val mixed = rotateLeftByte(
                (substituted + neighbor + lane + round * 9 + index * 13) and 0xFF,
                ((round + blockIndex + index) % 7) + 1
            )
            output[index] = (mixed xor roundKey[(index + 5) % HALF_BLOCK_SIZE].toInt() xor stateByte).toByte()
        }

        return output
    }

    private fun roundFunctionV5(
        right: ByteArray,
        roundKey: ByteArray,
        roundTweak: ByteArray,
        round: Int,
        blockIndex: Int,
        masterState: ByteArray,
        primarySBox: IntArray,
        secondarySBox: IntArray,
        tweak: ByteArray
    ): ByteArray {
        val laneSeed = digest512(
            right +
                roundKey +
                roundTweak +
                intToBytes(round) +
                intToBytes(blockIndex) +
                tweak +
                windowBytes(masterState, (round * 7 + blockIndex * 13) % masterState.size, BLOCK_SIZE)
        )
        val output = ByteArray(HALF_BLOCK_SIZE)

        for (index in 0 until HALF_BLOCK_SIZE) {
            val base = right[index].toInt() and 0xFF
            val keyA = roundKey[(index + round) % HALF_BLOCK_SIZE].toInt() and 0xFF
            val keyB = roundTweak[(HALF_BLOCK_SIZE - 1 - index + blockIndex) % HALF_BLOCK_SIZE].toInt() and 0xFF
            val laneA = laneSeed[index].toInt() and 0xFF
            val laneB = laneSeed[index + HALF_BLOCK_SIZE].toInt() and 0xFF
            val tweakByte = tweak[(index * 3 + round) % BLOCK_SIZE].toInt() and 0xFF
            val neighbor = right[(index + 1) % HALF_BLOCK_SIZE].toInt() and 0xFF
            val stateA = masterState[(round * 17 + blockIndex * 11 + index * 7) % masterState.size].toInt() and 0xFF
            val stateB = masterState[(round * 19 + blockIndex * 5 + index * 13 + 3) % masterState.size].toInt() and 0xFF
            val first = primarySBox[(base xor keyA xor laneA xor tweakByte xor stateA) and 0xFF]
            val second = secondarySBox[(first + keyB + laneB + neighbor + stateB) and 0xFF]
            val rotated = rotateLeftByte(
                second xor keyA xor keyB xor laneA xor stateA,
                ((round + index + blockIndex) % 7) + 1
            )
            output[index] = (
                rotated xor
                    roundKey[(index + 5) % HALF_BLOCK_SIZE].toInt() xor
                    roundTweak[(index + 9) % HALF_BLOCK_SIZE].toInt() xor
                    laneB xor
                    stateB
                ).toByte()
        }

        return output
    }

    private fun buildPermutation(seed: ByteArray, size: Int): IntArray {
        val permutation = IntArray(size) { it }
        var state = digest512(seed)

        for (index in size - 1 downTo 1) {
            state = digest512(state + seed + index.toByte())
            val candidate = ((state[0].toInt() and 0xFF) shl 24) or
                ((state[1].toInt() and 0xFF) shl 16) or
                ((state[2].toInt() and 0xFF) shl 8) or
                (state[3].toInt() and 0xFF)
            val swapIndex = (candidate and Int.MAX_VALUE) % (index + 1)
            val temp = permutation[index]
            permutation[index] = permutation[swapIndex]
            permutation[swapIndex] = temp
        }

        return permutation
    }

    private fun buildInversePermutation(permutation: IntArray): IntArray {
        val inverse = IntArray(permutation.size)
        permutation.forEachIndexed { index, value -> inverse[value] = index }
        return inverse
    }

    private fun deriveBlockMask(masterState: ByteArray, nonce: ByteArray, blockIndex: Int, domain: ByteArray): ByteArray =
        digest512(domain + masterState + nonce + intToBytes(blockIndex)).copyOf(BLOCK_SIZE)

    private fun initialChainStateV5(context: CipherContext, nonce: ByteArray): ByteArray =
        digest512(V5_CHAIN_DOMAIN + nonce + context.masterState + context.preWhitening).copyOf(BLOCK_SIZE)

    private fun updateChainStateV5(block: ByteArray, tweak: ByteArray, masterState: ByteArray): ByteArray =
        xorThreeBlocks(
            digest512(
                V5_CHAIN_RESEED_DOMAIN +
                    block +
                    tweak +
                    windowBytes(masterState, block[0].toInt() and 0xFF, BLOCK_SIZE)
            ).copyOf(BLOCK_SIZE),
            block,
            tweak
        )

    private fun substituteBlock(block: ByteArray, box: IntArray): ByteArray {
        val output = ByteArray(block.size)
        for (index in block.indices) {
            output[index] = box[block[index].toInt() and 0xFF].toByte()
        }
        return output
    }

    private fun windowBytes(source: ByteArray, start: Int, length: Int): ByteArray {
        val output = ByteArray(length)
        for (index in 0 until length) {
            output[index] = source[(start + index) % source.size]
        }
        return output
    }

    private fun permuteBlock(block: ByteArray, permutation: IntArray): ByteArray {
        val output = ByteArray(block.size)
        for (index in block.indices) {
            output[index] = block[permutation[index]]
        }
        return output
    }

    private fun inversePermuteBlock(block: ByteArray, inversePermutation: IntArray): ByteArray {
        val output = ByteArray(block.size)
        for (index in block.indices) {
            output[index] = block[inversePermutation[index]]
        }
        return output
    }

    private fun digest256(input: ByteArray): ByteArray =
        MessageDigest.getInstance(SHA256).digest(input)

    private fun digest512(input: ByteArray): ByteArray =
        MessageDigest.getInstance(SHA512).digest(input)

    private fun expandState(seed: ByteArray, length: Int): ByteArray {
        val output = ByteArray(length)
        var state = digest512(seed)
        var offset = 0
        var counter = 0

        while (offset < length) {
            state = digest512(state + seed + intToBytes(counter))
            val chunkSize = minOf(state.size, length - offset)
            state.copyInto(output, offset, 0, chunkSize)
            offset += chunkSize
            counter++
        }

        return output
    }

    private fun xorThreeBlocks(source: ByteArray, offset: Int, first: ByteArray, second: ByteArray): ByteArray {
        val output = ByteArray(BLOCK_SIZE)
        for (index in 0 until BLOCK_SIZE) {
            output[index] = (
                (source[offset + index].toInt() and 0xFF) xor
                    (first[index].toInt() and 0xFF) xor
                    (second[index].toInt() and 0xFF)
                ).toByte()
        }
        return output
    }

    private fun xorThreeBlocks(left: ByteArray, first: ByteArray, second: ByteArray): ByteArray {
        val output = ByteArray(BLOCK_SIZE)
        for (index in 0 until BLOCK_SIZE) {
            output[index] = (
                (left[index].toInt() and 0xFF) xor
                    (first[index].toInt() and 0xFF) xor
                    (second[index].toInt() and 0xFF)
                ).toByte()
        }
        return output
    }

    private fun xorFourBlocks(source: ByteArray, offset: Int, first: ByteArray, second: ByteArray, third: ByteArray): ByteArray {
        val output = ByteArray(BLOCK_SIZE)
        for (index in 0 until BLOCK_SIZE) {
            output[index] = (
                (source[offset + index].toInt() and 0xFF) xor
                    (first[index].toInt() and 0xFF) xor
                    (second[index].toInt() and 0xFF) xor
                    (third[index].toInt() and 0xFF)
                ).toByte()
        }
        return output
    }

    private fun xorFourBlocks(left: ByteArray, first: ByteArray, second: ByteArray, third: ByteArray): ByteArray {
        val output = ByteArray(BLOCK_SIZE)
        for (index in 0 until BLOCK_SIZE) {
            output[index] = (
                (left[index].toInt() and 0xFF) xor
                    (first[index].toInt() and 0xFF) xor
                    (second[index].toInt() and 0xFF) xor
                    (third[index].toInt() and 0xFF)
                ).toByte()
        }
        return output
    }

    private fun xorTwoBlocks(left: ByteArray, right: ByteArray): ByteArray {
        val output = ByteArray(BLOCK_SIZE)
        for (index in 0 until BLOCK_SIZE) {
            output[index] = ((left[index].toInt() and 0xFF) xor (right[index].toInt() and 0xFF)).toByte()
        }
        return output
    }

    private fun xorHalfBlocks(left: ByteArray, right: ByteArray): ByteArray {
        val output = ByteArray(HALF_BLOCK_SIZE)
        for (index in 0 until HALF_BLOCK_SIZE) {
            output[index] = ((left[index].toInt() and 0xFF) xor (right[index].toInt() and 0xFF)).toByte()
        }
        return output
    }

    private fun rotateLeftByte(value: Int, shift: Int): Int {
        val resolvedShift = shift and 7
        return ((value shl resolvedShift) or (value ushr (8 - resolvedShift))) and 0xFF
    }

    private fun intToBytes(value: Int): ByteArray =
        byteArrayOf(
            (value ushr 24).toByte(),
            (value ushr 16).toByte(),
            (value ushr 8).toByte(),
            value.toByte()
        )
    private fun pad(input: ByteArray): ByteArray {
        val paddingLength = BLOCK_SIZE - (input.size % BLOCK_SIZE)
        return input + ByteArray(paddingLength) { paddingLength.toByte() }
    }

    private fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean {
        if (left.size != right.size) return false
        var diff = 0
        for (index in left.indices) {
            diff = diff or ((left[index].toInt() and 0xFF) xor (right[index].toInt() and 0xFF))
        }
        return diff == 0
    }

    private fun clearContext(context: CipherContext) {
        context.masterState.fill(0)
        context.roundKeys.forEach { it.fill(0) }
        context.roundTweaks.forEach { it.fill(0) }
        context.primarySBox.fill(0)
        context.inversePrimarySBox.fill(0)
        context.secondarySBox.fill(0)
        context.inverseSecondarySBox.fill(0)
        context.entryPermutation.fill(0)
        context.inverseEntryPermutation.fill(0)
        context.exitPermutation.fill(0)
        context.inverseExitPermutation.fill(0)
        context.preWhitening.fill(0)
        context.postWhitening.fill(0)
    }

    private fun validatePlainText(plainText: String) {
        require(plainText.isNotBlank()) { "原文不能为空。" }
    }

    private fun validateCipherText(traditionalCipherText: String) {
        require(traditionalCipherText.isNotBlank()) { "密文不能为空。" }
    }

    private fun buildHeader(
        version: Byte,
        rounds: Int,
        saltLength: Int,
        nonceLength: Int,
        tagLength: Int,
        plainLength: Int
    ): ByteArray = ByteBuffer.allocate(HEADER_LENGTH)
        .put(version)
        .put(rounds.toByte())
        .put(saltLength.toByte())
        .put(nonceLength.toByte())
        .put(tagLength.toByte())
        .putInt(plainLength)
        .array()

    private data class PayloadHeader(
        val version: Byte,
        val rounds: Int,
        val saltLength: Int,
        val nonceLength: Int,
        val tagLength: Int,
        val plainLength: Int
    )

    private data class PayloadParts(
        val salt: ByteArray,
        val nonce: ByteArray,
        val cipherBytes: ByteArray,
        val tag: ByteArray
    )

    private data class CipherContext(
        val rounds: Int,
        val masterState: ByteArray,
        val roundKeys: Array<ByteArray>,
        val roundTweaks: Array<ByteArray>,
        val primarySBox: IntArray,
        val inversePrimarySBox: IntArray,
        val secondarySBox: IntArray,
        val inverseSecondarySBox: IntArray,
        val entryPermutation: IntArray,
        val inverseEntryPermutation: IntArray,
        val exitPermutation: IntArray,
        val inverseExitPermutation: IntArray,
        val preWhitening: ByteArray,
        val postWhitening: ByteArray
    )

    companion object {
        private const val SHA256 = "SHA-256"
        private const val SHA512 = "SHA-512"
        private const val HEADER_LENGTH = 9
        private const val BLOCK_SIZE = 32
        private const val HALF_BLOCK_SIZE = 16

        private const val VERSION_V4: Byte = 4
        private const val VERSION_V5: Byte = 5

        private const val DEFAULT_ROUNDS_V4 = 32
        private const val DEFAULT_ROUNDS_V5 = 48
        private const val MIN_ROUNDS_V4 = 12
        private const val MIN_ROUNDS_V5 = 24

        private const val KEY_STRETCH_CYCLES_V4 = 2048
        private const val KEY_STRETCH_CYCLES_V5 = 4096
        private const val MASTER_STATE_LENGTH_V5 = 128

        private const val SALT_LENGTH_V4 = 24
        private const val NONCE_LENGTH_V4 = 24
        private const val TAG_LENGTH_V4 = 24
        private const val MIN_SALT_LENGTH_V4 = 16
        private const val MIN_NONCE_LENGTH_V4 = 16

        private const val SALT_LENGTH_V5 = 32
        private const val NONCE_LENGTH_V5 = 32
        private const val TAG_LENGTH_V5 = 32
        private const val MIN_SALT_LENGTH_V5 = 24
        private const val MIN_NONCE_LENGTH_V5 = 24

        private val V4_TAG_DOMAIN = "ESA-X2-TAG".toByteArray(StandardCharsets.UTF_8)
        private val V4_CHAIN_DOMAIN = "ESA-X2-CHAIN".toByteArray(StandardCharsets.UTF_8)
        private val V4_PRE_MASK_DOMAIN = "ESA-X2-PRE".toByteArray(StandardCharsets.UTF_8)
        private val V4_POST_MASK_DOMAIN = "ESA-X2-POST".toByteArray(StandardCharsets.UTF_8)
        private val V4_SBOX_DOMAIN = "ESA-X2-SBOX".toByteArray(StandardCharsets.UTF_8)
        private val V4_BLOCK_DOMAIN = "ESA-X2-BLOCK".toByteArray(StandardCharsets.UTF_8)

        private val V5_SEED_DOMAIN = "ESA-X3-SEED".toByteArray(StandardCharsets.UTF_8)
        private val V5_STATE_DOMAIN = "ESA-X3-STATE".toByteArray(StandardCharsets.UTF_8)
        private val V5_STRETCH_A_DOMAIN = "ESA-X3-STRETCH-A".toByteArray(StandardCharsets.UTF_8)
        private val V5_STRETCH_B_DOMAIN = "ESA-X3-STRETCH-B".toByteArray(StandardCharsets.UTF_8)
        private val V5_RESEED_DOMAIN = "ESA-X3-RESEED".toByteArray(StandardCharsets.UTF_8)
        private val V5_MASTER_DOMAIN = "ESA-X3-MASTER".toByteArray(StandardCharsets.UTF_8)
        private val V5_ROUND_KEY_DOMAIN = "ESA-X3-ROUND-KEY".toByteArray(StandardCharsets.UTF_8)
        private val V5_ROUND_TWEAK_DOMAIN = "ESA-X3-ROUND-TWEAK".toByteArray(StandardCharsets.UTF_8)
        private val V5_SBOX_A_DOMAIN = "ESA-X3-SBOX-A".toByteArray(StandardCharsets.UTF_8)
        private val V5_SBOX_B_DOMAIN = "ESA-X3-SBOX-B".toByteArray(StandardCharsets.UTF_8)
        private val V5_ENTRY_DOMAIN = "ESA-X3-ENTRY".toByteArray(StandardCharsets.UTF_8)
        private val V5_EXIT_DOMAIN = "ESA-X3-EXIT".toByteArray(StandardCharsets.UTF_8)
        private val V5_PRE_WHITEN_DOMAIN = "ESA-X3-PRE-W".toByteArray(StandardCharsets.UTF_8)
        private val V5_POST_WHITEN_DOMAIN = "ESA-X3-POST-W".toByteArray(StandardCharsets.UTF_8)
        private val V5_TWEAK_DOMAIN = "ESA-X3-TWEAK".toByteArray(StandardCharsets.UTF_8)
        private val V5_PRE_MASK_DOMAIN = "ESA-X3-PRE".toByteArray(StandardCharsets.UTF_8)
        private val V5_POST_MASK_DOMAIN = "ESA-X3-POST".toByteArray(StandardCharsets.UTF_8)
        private val V5_CHAIN_DOMAIN = "ESA-X3-CHAIN".toByteArray(StandardCharsets.UTF_8)
        private val V5_CHAIN_RESEED_DOMAIN = "ESA-X3-CHAIN-R".toByteArray(StandardCharsets.UTF_8)
        private val V5_TAG_DOMAIN = "ESA-X3-TAG".toByteArray(StandardCharsets.UTF_8)
        private val V5_TAG_RESEAL_DOMAIN = "ESA-X3-TAG-R".toByteArray(StandardCharsets.UTF_8)
    }
}
