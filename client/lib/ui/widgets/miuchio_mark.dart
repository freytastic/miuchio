import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:miuchio/ui/theme/warm_tokens.dart';

// brand/icon-tab.svg geometry. Its masked gap is painted in the colour the
// mark sits on, since a mask needs no transparency here
class MiuchioMark extends StatelessWidget {
  final double size;
  final Color ground;

  const MiuchioMark({super.key, this.size = 20, this.ground = Warm.groundLift});

  static const _m =
      'M24 76 V56 A11.5 11.5 0 0 1 47 56 V76 M47 56 A11.5 11.5 0 0 1 70 56 V76';

  String get _svg {
    final gap =
        '#${(ground.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="18 18 67 67">'
        '<g transform="translate(68 39) rotate(14)">'
        '<rect fill="#3B281E" x="-12.5" y="-15" width="25" height="30" rx="2.2"/>'
        '<rect fill="#F6D2AB" x="-9.5" y="-12" width="19" height="19" rx="1"/>'
        '</g>'
        '<path d="$_m" fill="none" stroke="$gap" stroke-width="17" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        '<path d="$_m" fill="none" stroke="#3B281E" stroke-width="10" '
        'stroke-linecap="round" stroke-linejoin="round"/>'
        '</svg>';
  }

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string(_svg, width: size, height: size);
}
