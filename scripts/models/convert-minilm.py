# /// script
# requires-python = "==3.12.*"
# dependencies = ["torch==2.5.1", "transformers==4.46.3", "coremltools==8.1", "numpy<2.1", "huggingface_hub"]
# ///
"""Builds Vendor/MiniLM/MiniLM.mlpackage from sentence-transformers/all-MiniLM-L6-v2
(Apache-2.0) for on-device semantic search (#157).

The Core ML model takes WordPiece token IDs and an attention mask, 128 long,
and returns the sentence embedding: the attention-masked mean of the last
hidden states, normalised to unit length, as sentence-transformers computes
it. Weights are quantised to 8 bits. The tokenizer is BoopstashCore's
WordPieceTokenizer, reading the same vocab.txt.

Run: uv run scripts/models/convert-minilm.py <output folder>
"""
import sys, shutil, pathlib
import numpy as np
import torch
from transformers import AutoModel, AutoTokenizer
import coremltools as ct
import coremltools.optimize.coreml as cto

REPO = "sentence-transformers/all-MiniLM-L6-v2"
REVISION = "c9745ed1d9f207416be6d2e6f8de32d1f16199bf"
LENGTH = 128

out = pathlib.Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
tokenizer = AutoTokenizer.from_pretrained(REPO, revision=REVISION)
model = AutoModel.from_pretrained(REPO, revision=REVISION, torchscript=True).eval()

class Embedder(torch.nn.Module):
    def __init__(self, bert):
        super().__init__()
        self.bert = bert
    def forward(self, input_ids, attention_mask):
        hidden = self.bert(input_ids=input_ids, attention_mask=attention_mask)[0]
        mask = attention_mask.unsqueeze(-1).to(hidden.dtype)
        mean = (hidden * mask).sum(1) / mask.sum(1).clamp(min=1e-9)
        return torch.nn.functional.normalize(mean, p=2, dim=1)

wrapped = Embedder(model).eval()
example = tokenizer("an example", padding="max_length", max_length=LENGTH, truncation=True, return_tensors="pt")
traced = torch.jit.trace(wrapped, (example["input_ids"].int(), example["attention_mask"].int()))
mlmodel = ct.convert(
    traced,
    inputs=[ct.TensorType(name="input_ids", shape=(1, LENGTH), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, LENGTH), dtype=np.int32)],
    outputs=[ct.TensorType(name="embedding")],
    minimum_deployment_target=ct.target.macOS14,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel = cto.linear_quantize_weights(mlmodel, cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric")))
mlmodel.short_description = "all-MiniLM-L6-v2 sentence embeddings (Apache-2.0), mean-pooled and normalised"
target = out / "MiniLM.mlpackage"
if target.exists():
    shutil.rmtree(target)
mlmodel.save(str(target))
from huggingface_hub import hf_hub_download
shutil.copy(hf_hub_download(REPO, "vocab.txt", revision=REVISION), out / "vocab.txt")

# A check against the reference: the same sentences through PyTorch.
sentences = ["invoice", "bill for March", "Weekly signups by region"]
for s in sentences:
    enc = tokenizer(s, padding="max_length", max_length=LENGTH, truncation=True, return_tensors="np")
    ours = mlmodel.predict({"input_ids": enc["input_ids"].astype(np.int32), "attention_mask": enc["attention_mask"].astype(np.int32)})["embedding"][0]
    with torch.no_grad():
        ref = wrapped(torch.tensor(enc["input_ids"]).int(), torch.tensor(enc["attention_mask"]).int())[0].numpy()
    print(f"{s!r}: cosine to reference {float(np.dot(ours, ref)):.4f}; ids {enc['input_ids'][0][:8].tolist()}")
