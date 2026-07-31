import 'package:flutter_test/flutter_test.dart';
import 'package:my_translate/services/translation_router.dart';

void main() {
  group('TranslationRouter.route — §8.3 边界用例', () {
    test('"这个OK吗" | A | 任意 → source=zh（中文字符占主导）', () {
      final r = TranslationRouter.route('这个OK吗', 'zhEn');
      expect(r, isNotNull);
      expect(r!.source, equals(SrcLang.zh));
      expect(r.target, equals('en'));
    });

    test('"OK" | A | sticky=zh → 返回 null（INV-STICKY-SHORT，沿用 zh）', () {
      final r = TranslationRouter.route('OK', 'zhEn', stickyLang: 'zh');
      expect(r, isNull);
    });

    test('"OK" | A | sticky=en → 返回 en（mapped==sticky 不误拦截）', () {
      final r = TranslationRouter.route('OK', 'zhEn', stickyLang: 'en');
      expect(r, isNotNull);
      expect(r!.source, equals(SrcLang.en));
      expect(r.target, equals('zh'));
    });

    test('"Hello, how are you" | A | 任意 → source=en（长度够，不触发短文本保护）', () {
      final r = TranslationRouter.route('Hello, how are you', 'zhEn');
      expect(r, isNotNull);
      expect(r!.source, equals(SrcLang.en));
      expect(r.target, equals('zh'));
    });

    test('"123456" | 任意 | sticky=zh → 返回 null（纯数字，沿用 zh）', () {
      final r = TranslationRouter.route('123456', 'zhEn', stickyLang: 'zh');
      expect(r, isNull);
    });

    test('"Привет" | B | sticky=zh → source=ru（西里尔主导，超阈值）', () {
      final r = TranslationRouter.route('Привет', 'zhRu', stickyLang: 'zh');
      expect(r, isNotNull);
      expect(r!.source, equals(SrcLang.ru));
      expect(r.target, equals('zh'));
    });

    test('"" | 任意 | 任意 → 返回 null（空串）', () {
      final r = TranslationRouter.route('', 'zhEn');
      expect(r, isNull);
    });

    test('手动 Chip 优先：manualLang=ru 覆盖字符集判定（INV-MANUAL）', () {
      // 即使文本是中文，手动指定 ru 也必须返回 ru
      final r = TranslationRouter.route('你好', 'zhRu', manualLang: 'ru');
      expect(r, isNotNull);
      expect(r!.source, equals(SrcLang.ru));
      expect(r.target, equals('zh'));
    });

    test('模式 B 下拉丁主导视为噪声 → null', () {
      // 模式 B 不应出现拉丁主导，按噪声处理
      final r = TranslationRouter.route('Hello', 'zhRu', stickyLang: 'zh');
      expect(r, isNull);
    });

    test('模式 A 下西里尔主导视为噪声 → null', () {
      final r = TranslationRouter.route('Привет', 'zhEn', stickyLang: 'zh');
      expect(r, isNull);
    });
  });
}
