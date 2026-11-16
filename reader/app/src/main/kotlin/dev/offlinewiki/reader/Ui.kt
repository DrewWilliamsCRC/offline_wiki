package dev.offlinewiki.reader

import android.content.Context
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.TextView

/** Small view helpers shared by the screens. Everything is plain black on white for e-ink. */
object Ui {
    fun dp(context: Context, value: Int): Int = (value * context.resources.displayMetrics.density + 0.5f).toInt()

    /**
     * A flat, bordered button. No ripple or elevation: those animate, and e-ink smears animation.
     * With [fit], for buttons given a fixed share of a row, the label stays on one line and shrinks
     * if it must: e-readers are often set to a large system font, which otherwise wraps "Search".
     */
    fun button(context: Context, label: String, fit: Boolean = false, onClick: () -> Unit): TextView =
        TextView(context).apply {
            text = label
            typeface = Typeface.DEFAULT_BOLD
            gravity = Gravity.CENTER
            setTextColor(Color.BLACK)
            background = border(context)
            minimumHeight = dp(context, 48)
            if (fit) fitOneLine(this, 18) else textSize = 18f
            val side = dp(context, if (fit) 4 else 10)
            setPadding(side, 0, side, 0)
            setOnClickListener { onClick() }
        }

    /** Keeps a fixed-width label on one line, at up to [maxSp] and smaller when space is short. */
    fun fitOneLine(view: TextView, maxSp: Int) {
        view.maxLines = 1
        view.setAutoSizeTextTypeUniformWithConfiguration(8, maxSp, 1, TypedValue.COMPLEX_UNIT_SP)
    }

    fun border(context: Context): GradientDrawable = GradientDrawable().apply {
        setColor(Color.WHITE)
        setStroke(dp(context, 1), Color.BLACK)
    }

    /** A one-pixel-ish black rule. */
    fun rule(context: Context): View = View(context).apply {
        setBackgroundColor(Color.BLACK)
        minimumHeight = dp(context, 1)
    }
}
