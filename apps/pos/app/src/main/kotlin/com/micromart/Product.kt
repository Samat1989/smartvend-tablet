package com.micromart

data class Product(
    val id: String,
    val name: String,
    val price: Int,        // тийын (тенге * 100)
    val emoji: String,
    val stock: Int,
    val imagePath: String? = null
)
