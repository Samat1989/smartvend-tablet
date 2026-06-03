package com.micromart

import android.graphics.BitmapFactory
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class ServiceProductAdapter(
    private var products: MutableList<Product>,
    private val onEdit: (Product) -> Unit,
    private val onDelete: (Product) -> Unit
) : RecyclerView.Adapter<ServiceProductAdapter.ViewHolder>() {

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val ivImage: ImageView  = view.findViewById(R.id.ivProductImage)
        val tvEmoji: TextView   = view.findViewById(R.id.tvEmoji)
        val tvName: TextView    = view.findViewById(R.id.tvName)
        val tvPrice: TextView   = view.findViewById(R.id.tvPrice)
        val tvStock: TextView   = view.findViewById(R.id.tvStock)
        val btnEdit: Button     = view.findViewById(R.id.btnEdit)
        val btnDelete: Button   = view.findViewById(R.id.btnDelete)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_service_product, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val product = products[position]

        holder.tvName.text  = product.name
        holder.tvPrice.text = "${product.price / 100} ₸"
        holder.tvStock.text = "Остаток: ${product.stock} шт"
        holder.tvStock.setTextColor(
            if (product.stock > 0) 0xFF757575.toInt() else 0xFFD32F2F.toInt()
        )

        // Фото или эмодзи
        val imgPath = product.imagePath
        if (!imgPath.isNullOrEmpty()) {
            val bmp = runCatching { BitmapFactory.decodeFile(imgPath) }.getOrNull()
            if (bmp != null) {
                holder.ivImage.setImageBitmap(bmp)
                holder.ivImage.visibility = View.VISIBLE
                holder.tvEmoji.visibility = View.GONE
            } else {
                showEmoji(holder, product.emoji)
            }
        } else {
            showEmoji(holder, product.emoji)
        }

        holder.btnEdit.setOnClickListener   { onEdit(product) }
        holder.btnDelete.setOnClickListener { onDelete(product) }
    }

    override fun getItemCount() = products.size

    fun reload(newList: MutableList<Product>) {
        products = newList
        notifyDataSetChanged()
    }

    private fun showEmoji(holder: ViewHolder, emoji: String) {
        holder.tvEmoji.text = emoji
        holder.tvEmoji.visibility = View.VISIBLE
        holder.ivImage.visibility = View.GONE
    }
}
