package com.micromart

import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView

class CartActivity : AppCompatActivity() {

    private lateinit var adapter: CartAdapter
    private lateinit var tvTotal: TextView
    private lateinit var tvEmpty: TextView
    private lateinit var rvCart: RecyclerView
    private lateinit var btnCheckout: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_cart)

        tvTotal    = findViewById(R.id.tvTotal)
        tvEmpty    = findViewById(R.id.tvEmpty)
        rvCart     = findViewById(R.id.rvCart)
        btnCheckout = findViewById(R.id.btnCheckout)

        val items = CartManager.getItems().map { (p, q) -> p to q }.toMutableList()
        adapter = CartAdapter(items) { updateFooter() }

        rvCart.layoutManager = LinearLayoutManager(this)
        rvCart.adapter = adapter

        updateFooter()

        findViewById<Button>(R.id.btnBack).setOnClickListener { finish() }

        findViewById<Button>(R.id.btnClear).setOnClickListener {
            CartManager.clear()
            adapter.reload()
            updateFooter()
        }

        btnCheckout.setOnClickListener {
            if (CartManager.getTotalCount() == 0) return@setOnClickListener
            val intent = Intent(this, QrActivity::class.java).apply {
                putExtra("product_name", buildOrderName())
                putExtra("product_price", CartManager.getTotal())
            }
            startActivity(intent)
        }
    }

    override fun onResume() {
        super.onResume()
        adapter.reload()
        updateFooter()
    }

    private fun updateFooter() {
        val total = CartManager.getTotal()
        val count = CartManager.getTotalCount()
        tvTotal.text = "${total / 100} ₸"
        btnCheckout.isEnabled = count > 0
        tvEmpty.visibility = if (count == 0) View.VISIBLE else View.GONE
        rvCart.visibility  = if (count == 0) View.GONE else View.VISIBLE
    }

    private fun buildOrderName(): String {
        val items = CartManager.getItems()
        if (items.isEmpty()) return "Заказ"

        // Разворачиваем с учётом количества: Кола x2 → [Кола; Кола]
        val nameList = items.entries.flatMap { (product, qty) ->
            List(qty) { product.name }
        }
        return if (nameList.size == 1) nameList.first()
        else "[${nameList.joinToString("; ")}]"
    }
}
