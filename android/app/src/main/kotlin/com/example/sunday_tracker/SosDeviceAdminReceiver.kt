package com.example.sunday_tracker

import android.app.admin.DeviceAdminReceiver

/**
 * Administrateur d'appareil minimal — sert uniquement à obtenir le droit
 * `force-lock`, seul moyen supporté pour qu'une application verrouille l'écran
 * elle-même (DevicePolicyManager.lockNow()).
 *
 * Aucune politique n'est appliquée : pas d'effacement à distance, pas de
 * contrainte de mot de passe. Voir res/xml/sos_device_admin.xml.
 */
class SosDeviceAdminReceiver : DeviceAdminReceiver()
