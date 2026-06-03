package com.micromart

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

class CartAdapter(
    private var items: MutableList<Pair<Product, Int>>,
    private val onChanged: () -> Unit
) : RecyclerView.Adapter<CartAdapter.ViewHolder>() {

    inner class ViewHolder(view: View) : RecyclerView.ViewHolder(view) {
        val tvEmoji: TextView    = view.findViewById(R.id.tvEmoji)
        val tvName: TextView     = view.findViewById(R.id.tvName)
        val tvUnitPrice: TextView = view.findViewById(R.id.tvUnitPrice)
        val tvQty: TextView      = view.findViewById(R.id.tvQty)
        val tvSubtotal: TextView = view.findViewById(R.id.tvSubtotal)
        val btnPlus: Button      = view.findViewById(R.id.btnPlus)
        val btnMinus: Button     = view.findViewById(R.id.btnMinus)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
        val view = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_cart, parent, false)
        return ViewHolder(view)
    }

    override fun onBindViewHolder(holder: ViewHolder, position: Int) {
        val (product, qty) = items[position]

        holder.tvEmoji.text     = product.emoji
        holder.tvName.text      = product.name
        holder.tvUnitPrice.text = "${product.price / 100} ₸ / шт"
        holder.tvQty.text       = qty.toString()
        holder.tvSubtotal.text  = "${product.price * qty / 100} ₸"

        holder.btnPlus.setOnClickListener {
            CartManager.add(product)
            items[position] = product to (qty + 1)
            notifyItemChanged(position)
            onChanged()
        }

        holder.btnMinus.setOnClickListener {
            CartManager.remove(product)
            val newQty = qty - 1
            if (newQty <= 0) {
                items.removeAt(position)
                notifyItemRemoved(position)
                notifyItemRangeChanged(position, items.size)
            } else {
                items[position] = product to newQty
                notifyItemChanged(position)
            }
            onChanged()
        }
    }

    override fun getItemCount() = items.size

    fun reload() {
        items = CartManager.getItems().map { (p, q) -> p to q }.toMutableList()
        notifyDataSetChanged()
    }
}
