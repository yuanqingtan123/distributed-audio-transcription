from dataclasses import dataclass, field
from typing import cast, Any
from omegaconf import OmegaConf


@dataclass
class SSHConfig:
    alias: str
    host: str
    user: str
    port: int
    password: str
    workload_weight: int


@dataclass
class Config:
    configs: list[SSHConfig] = field(default_factory=list)

    @staticmethod
    def from_yaml(path: str = "ssh_configs.yaml") -> "Params":
        base_cfg = OmegaConf.structured(Config)
        cfg = OmegaConf.load(path)
        merged_cfg = OmegaConf.merge(base_cfg, cfg)

        return OmegaConf.to_object(merged_cfg)
