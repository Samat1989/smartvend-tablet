package com.micromart

object CartManager {
    private val items = mutableMapOf<Product, Int>()

    fun add(product: Product) {
        items[product] = (items[product] ?: 0) + 1
    }

    fun remove(product: Product) {
        val current = items[product] ?: return
        if (current <= 1) items.remove(product) else items[product] = current - 1
    }

    fun setQuantity(product: Product, qty: Int) {
        if (qty <= 0) items.remove(product) else items[product] = qty
    }

    fun getQuantity(product: Product): Int = items[product] ?: 0

    fun getItems(): Map<Product, Int> = items.toMap()

    fun getTotal(): Int = items.entries.sumOf { it.key.price * it.value }

    fun getTotalCount(): Int = items.values.sum()

    fun clear() = items.clear()
}
