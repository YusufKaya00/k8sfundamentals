"""ResilienceStream paket başlatıcısı.

Bu paket; FastAPI sipariş servisi (`order-api`), Kafka analitik tüketicisi
(`analytics-consumer`) ve RabbitMQ ödeme işçisini (`payment-worker`) tek bir
konteyner imajı (`yusufk00/resiliencestream`) içinde birleştirir.
"""
