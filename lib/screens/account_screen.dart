import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/account_service.dart';

/// Écran « Mon compte » : sauvegarder ses sorties (rattacher un email au compte
/// anonyme) ou se reconnecter à un compte existant après réinstallation.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key, this.onRecovered});

  /// Appelé après une récupération réussie (Flow B) : l'accueil s'en sert pour
  /// rapatrier l'historique du compte retrouvé.
  final Future<void> Function()? onRecovered;

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

enum _Mode { save, recover }

enum _Step { chooser, email, code, done }

const _kAccent = Color(0xFFD946EF);
const _kBg = Color(0xFF0D0D0D);

class _AccountScreenState extends State<AccountScreen> {
  static const int _codeLength = 6;

  final _service = AccountService();
  final _emailCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();

  _Mode _mode = _Mode.save;
  _Step _step = _Step.chooser;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    // Repeint les cases OTP quand le focus change (case active surlignée).
    _codeFocus.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _codeCtrl.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _sendCode() async {
    final email = _emailCtrl.text.trim();
    if (!AccountService.isValidEmail(email)) {
      _snack('Adresse email invalide.');
      return;
    }
    setState(() => _loading = true);
    try {
      if (_mode == _Mode.save) {
        await _service.sendSaveCode(email);
      } else {
        await _service.sendRecoverCode(email);
      }
      if (!mounted) return;
      setState(() => _step = _Step.code);
    } on AccountException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmCode() async {
    final email = _emailCtrl.text.trim();
    final code = _codeCtrl.text.trim();
    if (code.length < 6) {
      _snack('Entre le code reçu par email.');
      return;
    }
    setState(() => _loading = true);
    try {
      if (_mode == _Mode.save) {
        await _service.confirmSaveCode(email, code);
      } else {
        await _service.confirmRecoverCode(email, code);
        await widget.onRecovered?.call();
      }
      if (!mounted) return;
      setState(() => _step = _Step.done);
    } on AccountException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _startFlow(_Mode mode) {
    setState(() {
      _mode = mode;
      _step = _Step.email;
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _service.currentStatus();

    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        title: const Text('Mon compte'),
        elevation: 0,
      ),
      body: SafeArea(
        // Défilable si le contenu dépasse (petit écran / clavier), tout en
        // laissant les Spacer remplir la hauteur quand il y a la place.
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: IntrinsicHeight(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _buildBody(status),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildBody(AccountStatus status) {
    // Compte déjà sauvegardé : on affiche l'état par défaut. Mais si l'utilisateur
    // a lancé un parcours (ex. « Utiliser un autre compte »), on le laisse suivre.
    if (status.isSaved && _step == _Step.chooser) {
      return _savedState(status);
    }
    switch (_step) {
      case _Step.chooser:
        return _chooser();
      case _Step.email:
        return _emailStep();
      case _Step.code:
        return _codeStep();
      case _Step.done:
        return _doneStep();
    }
  }

  // --- Vues ------------------------------------------------------------------

  Widget _savedState(AccountStatus status) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 40),
        Center(child: _bigSavedIcon()),
        const SizedBox(height: 32),
        const Text(
          'Sorties sauvegardées',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 24),
        const Text(
          'Ton historique est rattaché à',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 15),
        ),
        const SizedBox(height: 14),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1A1A),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              status.email ?? '',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        const SizedBox(height: 28),
        const Text(
          'Tu peux réinstaller l\'appli ou changer de téléphone :\n'
          'tes sorties te suivront.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white38, fontSize: 14, height: 1.5),
        ),
        const Spacer(),
        SizedBox(
          height: 56,
          child: OutlinedButton(
            onPressed: () => _startFlow(_Mode.recover),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0xFF3A3A3A)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: const Text(
              'Utiliser un autre compte',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _chooser() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text(
          'Ne perds jamais tes sorties',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        const Text(
          'Pour l\'instant, tes sorties vivent uniquement sur ce téléphone. '
          'Rattache-les à ton email pour les retrouver après une réinstallation '
          'ou sur un autre appareil.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        const SizedBox(height: 32),
        _primaryButton(
          label: 'Sauvegarder mes sorties',
          icon: Icons.save_alt,
          onTap: () => _startFlow(_Mode.save),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () => _startFlow(_Mode.recover),
          child: const Text(
            'J\'ai déjà un compte, me reconnecter',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      ],
    );
  }

  Widget _emailStep() {
    final isSave = _mode == _Mode.save;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text(
          isSave ? 'Sauvegarder mes sorties' : 'Me reconnecter',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          isSave
              ? 'Entre ton email : on t\'enverra un code par email pour '
                  'rattacher tes sorties.'
              : 'Entre l\'email de ton compte : on t\'enverra un code pour te '
                  'reconnecter et retrouver ton historique.',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _emailCtrl,
          enabled: !_loading,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          style: const TextStyle(color: Colors.white),
          decoration: _fieldDecoration('ton@email.com'),
        ),
        const SizedBox(height: 24),
        _primaryButton(
          label: 'Recevoir le code',
          icon: Icons.mail_outline,
          onTap: _loading ? null : _sendCode,
          loading: _loading,
        ),
      ],
    );
  }

  Widget _codeStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text(
          'Entre le code',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          'On a envoyé un code par email à\n${_emailCtrl.text.trim()}',
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        const SizedBox(height: 24),
        _otpBoxes(),
        const SizedBox(height: 24),
        _primaryButton(
          label: 'Valider',
          icon: Icons.check,
          onTap: _loading ? null : _confirmCode,
          loading: _loading,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _loading ? null : _sendCode,
          child: const Text(
            'Renvoyer un code',
            style: TextStyle(color: Colors.white54),
          ),
        ),
      ],
    );
  }

  Widget _doneStep() {
    final isSave = _mode == _Mode.save;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        _bigSavedIcon(),
        const SizedBox(height: 20),
        Text(
          isSave ? 'C\'est sauvegardé' : 'Historique retrouvé',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          isSave
              ? 'Tes sorties sont rattachées à ton email. Elles te suivront '
                  'partout.'
              : 'Tu es reconnecté. Tes sorties réapparaissent dans l\'accueil.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        const SizedBox(height: 32),
        _primaryButton(
          label: 'Terminé',
          icon: Icons.done,
          onTap: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  // --- Widgets utilitaires ---------------------------------------------------

  /// Grand check dans un cercle (anneau vert + fond vert translucide).
  Widget _bigSavedIcon() {
    const green = Color(0xFF22C55E);
    return Container(
      width: 130,
      height: 130,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: green.withValues(alpha: 0.12),
        border: Border.all(color: green, width: 2),
      ),
      child: const Icon(Icons.check_rounded, color: green, size: 72),
    );
  }

  /// Saisie du code en 6 cases. Astuce : un seul TextField invisible par-dessus
  /// capte le clavier + l'autofill OTP (une seule zone = autofill fiable), et les
  /// 6 cases dessous ne font qu'afficher les chiffres.
  Widget _otpBoxes() {
    final text = _codeCtrl.text;
    final hasFocus = _codeFocus.hasFocus;
    return SizedBox(
      height: 56,
      child: Stack(
        children: [
          Row(
            children: List.generate(_codeLength, (i) {
              final filled = i < text.length;
              final active = hasFocus && i == text.length;
              return Expanded(
                child: Container(
                  height: 56,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: active ? _kAccent : const Color(0xFF2A2A2A),
                      width: active ? 1.6 : 1,
                    ),
                  ),
                  child: Text(
                    filled ? text[i] : '',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              );
            }),
          ),
          // Champ réel invisible : capte clavier + autofill (une seule zone).
          Positioned.fill(
            child: Opacity(
              opacity: 0,
              child: TextField(
                controller: _codeCtrl,
                focusNode: _codeFocus,
                enabled: !_loading,
                autofocus: true,
                showCursor: false,
                enableInteractiveSelection: false,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: _codeLength,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                cursorColor: Colors.transparent,
                style: const TextStyle(color: Colors.transparent),
                decoration: const InputDecoration(
                  counterText: '',
                  border: InputBorder.none,
                ),
                onChanged: (v) {
                  setState(() {});
                  if (v.length == _codeLength && !_loading) {
                    _codeFocus.unfocus();
                    _confirmCode();
                  }
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24),
      filled: true,
      fillColor: const Color(0xFF1A1A1A),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _kAccent, width: 1.5),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2A2A2A)),
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool loading = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.6 : 1,
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF6D28D9), Color(0xFFD946EF), Color(0xFFFF8A00)],
            ),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Center(
            child: loading
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: Colors.white,
                    ),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: Colors.white, size: 20),
                      const SizedBox(width: 10),
                      Text(
                        label,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
