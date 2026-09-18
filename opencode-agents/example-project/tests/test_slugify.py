import unittest

from textutils import slugify


class SlugifyTest(unittest.TestCase):
    def test_basic_lowercasing_and_space(self):
        self.assertEqual(slugify("Hello World"), "hello-world")

    def test_empty_string(self):
        self.assertEqual(slugify(""), "")

    def test_all_non_alphanumeric(self):
        self.assertEqual(slugify("!!! ???"), "")

    def test_hungarian_accents(self):
        self.assertEqual(slugify("Árvíztűrő"), "arvizturo")

    def test_run_of_punctuation_collapses(self):
        self.assertEqual(slugify("a---b"), "a-b")

    def test_leading_trailing_special_chars(self):
        self.assertEqual(slugify("--Start--End--"), "start-end")

    def test_mixed_spaces_and_punctuation(self):
        self.assertEqual(slugify("  Hello,   World!  "), "hello-world")

    def test_digits_kept(self):
        self.assertEqual(slugify("foo123-bar"), "foo123-bar")

    def test_explicit_none_max_length(self):
        self.assertEqual(slugify("hello world", None), "hello-world")

    def test_max_length_larger_than_slug(self):
        self.assertEqual(slugify("hello", 50), "hello")

    def test_max_length_equal_to_slug_length(self):
        self.assertEqual(slugify("hello-world", 11), "hello-world")

    def test_max_length_cutting_mid_word(self):
        self.assertEqual(slugify("hello-world", 9), "hello-wor")

    def test_max_length_landing_on_hyphen(self):
        self.assertEqual(slugify("hello-world", 6), "hello")

    def test_max_length_cut_shortens_after_hyphen_removal(self):
        self.assertEqual(slugify("a-b-c", 2), "a")

    def test_accents_and_max_length_combined(self):
        self.assertEqual(slugify("Árvíztűrő", 5), "arviz")

    def test_max_length_zero_raises(self):
        with self.assertRaises(ValueError):
            slugify("hello", 0)

    def test_max_length_negative_raises(self):
        with self.assertRaises(ValueError):
            slugify("hello", -1)


if __name__ == "__main__":
    unittest.main()
