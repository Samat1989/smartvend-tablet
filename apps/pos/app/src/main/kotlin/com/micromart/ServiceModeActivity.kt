package com.micromart

import android.content.Intent
import android.os.Bundle
import android.widget.Button
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.floatingactionbutton.FloatingActionButton

class ServiceModeActivity : AppCompatActivity() {

    private lateinit var adapter: ServiceProductAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_service_mode)

        findViewById<Button>(R.id.btnBack).setOnClickListener { finish() }

        adapter = ServiceProductAdapter(
            products  = ProductStore.getProducts(this),
            onEdit    = { product -> openEdit(product) },
            onDelete  = { product -> confirmDelete(product) }
        )

        findViewById<RecyclerView>(R.id.rvServiceProducts).apply {
            layoutManager = LinearLayoutManager(this@ServiceModeActivity)
            adapter = this@ServiceModeActivity.adapter
        }

        findViewById<FloatingActionButton>(R.id.fabAddProduct).setOnClickListener {
            openEdit(null)
        }

        findViewById<Button>(R.id.btnTestOpen).setOnClickListener {
            UsbController(this).openDoor { success, message ->
                runOnUiThread {
                    AlertDialog.Builder(this)
                        .setTitle(if (success) "Успех" else "Ошибка")
                        .setMessage(message)
                        .setPositiveButton("OK", null)
                        .show()
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        adapter.reload(ProductStore.getProducts(this))
    }

    private fun openEdit(product: Product?) {
        val intent = Intent(this, EditProductActivity::class.java)
        if (product != null) intent.putExtra("product_id", product.id)
        startActivity(intent)
    }

    private fun confirmDelete(product: Product) {
        AlertDialog.Builder(this)
            .setTitle("Удалить товар?")
            .setMessage("«${product.name}» будет удалён из списка.")
            .setPositiveButton("Удалить") { _, _ ->
                ProductStore.deleteProduct(this, product.id)
                adapter.reload(ProductStore.getProducts(this))
            }
            .setNegativeButton("Отмена", null)
            .show()
    }
}
