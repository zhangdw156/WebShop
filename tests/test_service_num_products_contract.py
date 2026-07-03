import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class WebShopServiceNumProductsContractTest(unittest.TestCase):
    def test_service_api_keeps_small_dataset_num_products_contract(self):
        source = (ROOT / "web_agent_site/service/api.py").read_text(encoding="utf-8")

        self.assertIn("num_products: Optional[int] = 1000", source)
        self.assertIn('"num_products": self.config.num_products', source)
        self.assertIn("num_products=self.config.num_products", source)
        self.assertIn('parser.add_argument("--num-products", type=_optional_num_products, default=1000)', source)
        self.assertIn("num_products=args.num_products", source)
        self.assertIn('value.lower() in {"none", "null", "all"}', source)

    def test_run_webshop_service_defaults_to_1k_index_and_allows_override(self):
        source = (ROOT / "run_webshop_service.sh").read_text(encoding="utf-8")

        self.assertIn("NUM_PRODUCTS=${NUM_PRODUCTS:-1000}", source)
        self.assertIn('ARGS+=(--num-products "${NUM_PRODUCTS}")', source)


if __name__ == "__main__":
    unittest.main()
