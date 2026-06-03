package com.micromart

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

object ProductStore {

    private const val PREFS_NAME = "product_store"
    private const val KEY_PRODUCTS = "products"

    fun getProducts(context: Context): MutableList<Product> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_PRODUCTS, null) ?: return mutableListOf()
        return parseProducts(JSONArray(json))
    }

    fun saveProducts(context: Context, products: List<Product>) {
        val arr = JSONArray()
        products.forEach { arr.put(toJson(it)) }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putString(KEY_PRODUCTS, arr.toString()).apply()
    }

    fun decreaseStock(context: Context, productId: String, qty: Int) {
        val products = getProducts(context)
        val idx = products.indexOfFirst { it.id == productId }
        if (idx >= 0) {
            val p = products[idx]
            products[idx] = p.copy(stock = maxOf(0, p.stock - qty))
            saveProducts(context, products)
        }
    }

    fun addProduct(context: Context, product: Product): Product {
        val products = getProducts(context)
        val nextId = java.util.UUID.randomUUID().toString()
        val newProduct = product.copy(id = nextId)
        products.add(newProduct)
        saveProducts(context, products)
        return newProduct
    }

    fun updateProduct(context: Context, product: Product) {
        val products = getProducts(context)
        val idx = products.indexOfFirst { it.id == product.id }
        if (idx >= 0) products[idx] = product
        saveProducts(context, products)
    }

    fun deleteProduct(context: Context, productId: String) {
        val products = getProducts(context)
        products.removeAll { it.id == productId }
        saveProducts(context, products)
    }

    private fun toJson(p: Product) = JSONObject().apply {
        put("id", p.id)
        put("name", p.name)
        put("price", p.price)
        put("emoji", p.emoji)
        put("stock", p.stock)
        put("imagePath", p.imagePath ?: JSONObject.NULL)
    }

    private fun parseProducts(arr: JSONArray): MutableList<Product> {
        val list = mutableListOf<Product>()
        for (i in 0 until arr.length()) {
            val o = arr.getJSONObject(i)
            list.add(Product(
                id        = o.getString("id"),
                name      = o.getString("name"),
                price     = o.getInt("price"),
                emoji     = o.getString("emoji"),
                stock     = o.getInt("stock"),
                imagePath = if (o.isNull("imagePath")) null else o.getString("imagePath")
            ))
        }
        return list
    }
}
