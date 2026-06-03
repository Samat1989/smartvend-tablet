package com.micromart

import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.view.View
import android.widget.Button
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView

class ProductsActivity : AppCompatActivity() {

    private var commandListener: CommandListener? = null
    private lateinit var btnCart: Button
    private lateinit var adapter: ProductAdapter
    private lateinit var rvProducts: RecyclerView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_products)

        btnCart    = findViewById(R.id.btnCart)
        rvProducts = findViewById(R.id.rvProducts)

        setupProductList()

        btnCart.setOnClickListener {
            adapter.collapseAll()
            startActivity(Intent(this, CartActivity::class.java))
        }

        // 'Secret' entrance to Service Mode (long click on header)
        findViewById<View>(R.id.tvHeader).setOnLongClickListener {
            startActivity(Intent(this, ServiceModeActivity::class.java))
            true
        }

        // Realtime commands (remote open)
        val prefs = getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
        val machid = prefs.getString(MainActivity.KEY_DEVICE_NUMBER, "") ?: ""
        if (machid.isNotEmpty()) {
            commandListener = CommandListener(this, machid)
            commandListener?.start()
        }
    }

    override fun onDestroy() {
        commandListener?.stop()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        setupProductList()
        updateCartButton()
        syncInventoryFromSupabase()
    }

    private fun syncInventoryFromSupabase() {
        val prefs = getSharedPreferences(MainActivity.PREFS_NAME, Context.MODE_PRIVATE)
        val machid = prefs.getString(MainActivity.KEY_DEVICE_NUMBER, "") ?: ""
        if (machid.isEmpty()) return

        Thread {
            val (freshProducts, errorMsg) = SupabaseApi.fetchInventory(machid)
            if (errorMsg != null) {
                android.util.Log.e("SupabaseApi", "fetchInventory failed: $errorMsg")
            }
            if (!freshProducts.isNullOrEmpty()) {
                runOnUiThread {
                    ProductStore.saveProducts(this, freshProducts)
                    setupProductList()
                }
            }
        }.start()
    }

    private fun setupProductList() {
        val products = ProductStore.getProducts(this).filter { it.stock > 0 }
        adapter = ProductAdapter(products) { updateCartButton() }
        rvProducts.layoutManager = GridLayoutManager(this, 2)
        rvProducts.adapter = adapter
        updateCartButton()
    }

    private fun updateCartButton() {
        val count = CartManager.getTotalCount()
        btnCart.text = "🛒 Корзина ($count)"
        btnCart.visibility = if (count > 0) View.VISIBLE else View.GONE
    }
}
