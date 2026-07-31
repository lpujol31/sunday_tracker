package com.example.sunday_tracker

import android.app.KeyguardManager
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val SOS_CHANNEL = "sunday_tracker/sos_lock"
    }

    private val adminComponent: ComponentName
        get() = ComponentName(this, SosDeviceAdminReceiver::class.java)

    private val devicePolicyManager: DevicePolicyManager
        get() = getSystemService(Context.DEVICE_POLICY_SERVICE) as DevicePolicyManager

    private val keyguardManager: KeyguardManager
        get() = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager

    override fun onCreate(savedInstanceState: Bundle?) {
        // Android 12+ : supprimer l'animation de sortie du splash natif.
        // Par défaut le système fait grossir + disparaître l'icône en fondu,
        // ce qui se superpose au logo Flutter (effet de « logo dédoublé/qui
        // saute ») au raccord natif → Flutter. On retire la vue d'un coup, sans
        // animation : le splash Flutter (logo calé au même endroit) prend le
        // relais sans artefact.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            splashScreen.setOnExitAnimationListener { view -> view.remove() }
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SOS_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "showOverLockScreen" -> {
                        val show = call.argument<Boolean>("show") ?: false
                        val turnScreenOn = call.argument<Boolean>("turnScreenOn") ?: false
                        setShowOverLockScreen(show, turnScreenOn)
                        result.success(null)
                    }
                    "isAdminActive" -> result.success(
                        devicePolicyManager.isAdminActive(adminComponent)
                    )
                    "requestAdmin" -> {
                        requestAdmin()
                        result.success(null)
                    }
                    "lockNow" -> {
                        if (devicePolicyManager.isAdminActive(adminComponent)) {
                            devicePolicyManager.lockNow()
                            result.success(true)
                        } else {
                            // Pas une erreur : côté Dart on propose alors
                            // d'activer l'admin, ou d'appuyer sur le bouton
                            // power à la main (le test reste concluant).
                            result.success(false)
                        }
                    }
                    "keyguardState" -> result.success(
                        mapOf(
                            "locked" to keyguardManager.isKeyguardLocked,
                            // false = aucun code/schéma configuré : l'écran de
                            // veille n'est alors qu'un simple swipe, le test
                            // n'est pas concluant.
                            "secure" to keyguardManager.isDeviceSecure,
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Affiche l'activité **au-dessus** de l'écran de verrouillage — le téléphone
     * reste verrouillé, on ne le déverrouille pas. C'est le mécanisme utilisé
     * par les applis de réveil et d'appel entrant.
     *
     * @param turnScreenOn rallume l'écran quand l'activité reprend le dessus.
     *   Volontairement dissocié de [show] : combiné à lockNow() il peut faire
     *   « rebondir » l'écran (extinction puis rallumage immédiat) selon le
     *   constructeur — à comparer sur appareil réel.
     */
    private fun setShowOverLockScreen(show: Boolean, turnScreenOn: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(show)
            setTurnScreenOn(show && turnScreenOn)
        } else {
            @Suppress("DEPRECATION")
            val flags = WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            if (show) window.addFlags(flags) else window.clearFlags(flags)
        }
    }

    private fun requestAdmin() {
        val intent = Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN).apply {
            putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent)
            putExtra(
                DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Autorise Sunday Tracker à verrouiller l'écran quand tu " +
                    "déclenches un SOS, pour afficher ta fiche d'urgence à un " +
                    "passant sans donner accès au reste du téléphone.",
            )
        }
        startActivity(intent)
    }
}
