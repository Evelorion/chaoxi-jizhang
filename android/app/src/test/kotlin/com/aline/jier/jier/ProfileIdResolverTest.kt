package com.aline.jier.jier

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ProfileIdResolverTest {
    @Test
    fun `parses owner user handle`() {
        assertEquals(0, ProfileIdResolver.parse("UserHandle{0}"))
    }

    @Test
    fun `parses work profile user handle`() {
        assertEquals(999, ProfileIdResolver.parse("UserHandle{999}"))
    }

    @Test
    fun `returns zero for blank values`() {
        assertEquals(0, ProfileIdResolver.parse(null))
        assertEquals(0, ProfileIdResolver.parse(""))
        assertEquals(0, ProfileIdResolver.parse("   "))
    }

    @Test
    fun `returns null for malformed user handles`() {
        assertNull(ProfileIdResolver.parse("UserHandle"))
        assertNull(ProfileIdResolver.parse("UserHandle{"))
        assertNull(ProfileIdResolver.parse("UserHandle{}"))
        assertNull(ProfileIdResolver.parse("UserHandle{abc"))
    }
}
