package com.aline.jier.jier

object ProfileIdResolver {
    fun parse(rawUser: String?): Int? {
        val normalized = rawUser?.trim().orEmpty()
        if (normalized.isBlank()) {
            return 0
        }

        val start = normalized.indexOf('{')
        if (start == -1) {
            return null
        }

        val end = normalized.indexOf('}', startIndex = start + 1)
        if (end == -1 || end <= start + 1) {
            return null
        }

        val digits = normalized.substring(start + 1, end)
            .filter(Char::isDigit)
        if (digits.isBlank()) {
            return null
        }

        return digits.toIntOrNull()
    }
}
