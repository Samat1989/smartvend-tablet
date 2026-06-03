package com.micromart

import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Bundle
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import java.io.File
import java.io.FileOutputStream

class EditProductActivity : AppCompatActivity() {

    private var pickedImagePath: String? = null
    private var existingImagePath: String? = null
    private var isNewProduct = true
    private var productId: String? = null

    private lateinit var ivPreview: ImageView
    private lateinit var tvEmojiPreview: TextView

    private val pickImageLauncher =
        registerForActivityResult(ActivityResultContracts.GetContent()) { uri: Uri? ->
            uri ?: return@registerForActivityResult
            val savedPath = copyImageToInternalStorage(uri)
            if (savedPath != null) {
                pickedImagePath = savedPath
                showImagePreview(savedPath)
            } else {
                Toast.makeText(this, "Не удалось загрузить изображение", Toast.LENGTH_SHORT).show()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_edit_product)

        ivPreview      = findViewById(R.id.ivPreview)
        tvEmojiPreview = findViewById(R.id.tvEmojiPreview)

        val tvTitle  = findViewById<TextView>(R.id.tvTitle)
        val etName   = findViewById<EditText>(R.id.etName)
        val etEmoji  = findViewById<EditText>(R.id.etEmoji)
        val etPrice  = findViewById<EditText>(R.id.etPrice)
        val etStock  = findViewById<EditText>(R.id.etStock)

        findViewById<Button>(R.id.btnBack).setOnClickListener { finish() }
        findViewById<Button>(R.id.btnPickImage).setOnClickListener {
            pickImageLauncher.launch("image/*")
        }

        productId = intent.getStringExtra("product_id")
        isNewProduct = productId == null

        if (!isNewProduct) {
            tvTitle.text = "Редактировать товар"
            val product = ProductStore.getProducts(this).firstOrNull { it.id == productId }
            if (product != null) {
                etName.setText(product.name)
                etEmoji.setText(product.emoji)
                etPrice.setText((product.price / 100).toString())
                etStock.setText(product.stock.toString())
                existingImagePath = product.imagePath
                if (!product.imagePath.isNullOrEmpty()) {
                    showImagePreview(product.imagePath)
                } else {
                    tvEmojiPreview.text = product.emoji
                }
            }
        } else {
            tvTitle.text = "Новый товар"
            tvEmojiPreview.text = "🛍"
        }

        etEmoji.setOnFocusChangeListener { _, _ ->
            val e = etEmoji.text.toString().trim()
            if (e.isNotEmpty() && pickedImagePath == null) {
                tvEmojiPreview.text = e
            }
        }

        findViewById<Button>(R.id.btnSave).setOnClickListener {
            val name  = etName.text.toString().trim()
            val emoji = etEmoji.text.toString().trim().ifEmpty { "🛍" }
            val priceStr = etPrice.text.toString().trim()
            val stockStr = etStock.text.toString().trim()

            if (name.isEmpty()) {
                Toast.makeText(this, "Введите название", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }
            if (priceStr.isEmpty()) {
                Toast.makeText(this, "Введите цену", Toast.LENGTH_SHORT).show()
                return@setOnClickListener
            }

            val priceTenge = priceStr.toIntOrNull() ?: 0
            val stock = stockStr.toIntOrNull() ?: 0
            val finalImagePath = pickedImagePath ?: existingImagePath

            if (isNewProduct) {
                ProductStore.addProduct(
                    this,
                    Product(id = "", name = name, price = priceTenge * 100,
                            emoji = emoji, stock = stock, imagePath = finalImagePath)
                )
                Toast.makeText(this, "Товар добавлен", Toast.LENGTH_SHORT).show()
            } else {
                ProductStore.updateProduct(
                    this,
                    Product(id = productId!!, name = name, price = priceTenge * 100,
                            emoji = emoji, stock = stock, imagePath = finalImagePath)
                )
                Toast.makeText(this, "Сохранено", Toast.LENGTH_SHORT).show()
            }
            finish()
        }
    }

    private fun showImagePreview(path: String) {
        val bmp = runCatching { BitmapFactory.decodeFile(path) }.getOrNull()
        if (bmp != null) {
            ivPreview.setImageBitmap(bmp)
            ivPreview.visibility = android.view.View.VISIBLE
            tvEmojiPreview.visibility = android.view.View.GONE
        }
    }

    private fun copyImageToInternalStorage(uri: Uri): String? {
        return try {
            val dir = File(filesDir, "product_images")
            dir.mkdirs()
            val file = File(dir, "img_${System.currentTimeMillis()}.jpg")
            contentResolver.openInputStream(uri)?.use { input ->
                FileOutputStream(file).use { output -> input.copyTo(output) }
            }
            file.absolutePath
        } catch (e: Exception) {
            null
        }
    }
}
