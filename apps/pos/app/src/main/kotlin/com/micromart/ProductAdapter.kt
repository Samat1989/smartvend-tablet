package com.micromart

import android.graphics.BitmapFactory
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class ProductAdapter(
    private val products: List<Product>,
    private val onCartChanged: () -> Unit
) : RecyclerView.Adapter<ProductAdapter.ViewHolder>() {

    private var selectedPosition = RecyclerView.NO_ID.toInt()

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val cardRoot: View          = view.findViewById(R.id.cardRoot)
        val ivImage: ImageView      = view.findViewById(R.id.ivProductImage)
        val tvEmoji: TextView       = view.findViewById(R.id.tvEmoji)
        val tvName: TextView        = view.findViewById(R.id.tvName)
        val tvPrice: TextView       = view.findViewById(R.id.tvPrice)
        val tvStock: TextView       = view.findViewById(R.id.tvStock)
        val tvQty: TextView         = view.findViewById(R.id.tvQty)
        val btnPlus: Button         = view.findViewById(R.id.btnPlus)
        val btnMinus: Button        = view.findViewById(R.id.btnMinus)
        val layoutControls: View    = view.findViewById(R.id.layoutControls)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_product, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val product = products[position]
        val qty = CartManager.getQuantity(product)
        val available = product.stock - qty
        val isExpanded = position == selectedPosition

        holder.tvName.text  = product.name
        holder.tvPrice.text = "${product.price / 100} ₸"
        holder.tvQty.text   = qty.toString()
        holder.tvStock.text = "Остаток: $available шт"
        holder.layoutControls.visibility = if (isExpanded) View.VISIBLE else View.GONE
        holder.btnPlus.isEnabled  = available > 0
        holder.btnMinus.isEnabled = qty > 0
        holder.btnPlus.alpha  = if (available > 0) 1f else 0.4f
        holder.btnMinus.alpha = if (qty > 0) 1f else 0.4f

        // Фото или эмодзи
        val imgPath = product.imagePath
        if (!imgPath.isNullOrEmpty()) {
            val bmp = runCatching { BitmapFactory.decodeFile(imgPath) }.getOrNull()
            if (bmp != null) {
                holder.ivImage.setImageBitmap(bmp)
                holder.ivImage.visibility = View.VISIBLE
                holder.tvEmoji.visibility = View.GONE
            } else {
                holder.tvEmoji.text = product.emoji
                holder.tvEmoji.visibility = View.VISIBLE
                holder.ivImage.visibility = View.GONE
            }
        } else {
            holder.tvEmoji.text = product.emoji
            holder.tvEmoji.visibility = View.VISIBLE
            holder.ivImage.visibility = View.GONE
        }

        holder.cardRoot.setOnClickListener {
            val prev = selectedPosition
            selectedPosition = if (isExpanded) RecyclerView.NO_ID.toInt() else position
            if (prev != RecyclerView.NO_ID.toInt()) notifyItemChanged(prev)
            notifyItemChanged(position)
        }

        holder.btnPlus.setOnClickListener {
            val currentQty = CartManager.getQuantity(product)
            if (product.stock - currentQty > 0) {
                CartManager.add(product)
                notifyItemChanged(position)
                onCartChanged()
            }
        }

        holder.btnMinus.setOnClickListener {
            val currentQty = CartManager.getQuantity(product)
            if (currentQty > 0) {
                CartManager.remove(product)
                notifyItemChanged(position)
                onCartChanged()
            }
        }
    }

    override fun getItemCount() = products.size

    fun collapseAll() {
        val prev = selectedPosition
        selectedPosition = RecyclerView.NO_ID.toInt()
        if (prev != RecyclerView.NO_ID.toInt()) notifyItemChanged(prev)
    }
}
