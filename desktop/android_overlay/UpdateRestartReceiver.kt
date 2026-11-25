package __PACKAGE__

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** After an in-app update is installed, starts the desktop again. */
class UpdateRestartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        try {
            val i = Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            context.startActivity(i)
        } catch (_: Exception) {
            // Android may not allow it from the background; as the home
            // screen, the desktop comes back anyway with the Home button.
        }
    }
}
