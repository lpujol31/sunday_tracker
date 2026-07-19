package com.example.sunday_tracker

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
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
}
