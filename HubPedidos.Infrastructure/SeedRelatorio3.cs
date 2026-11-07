using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Infrastructure;

public static class SeedRelatorio3
{
    public static async Task PrepararAsync(HubDbContext db, CancellationToken ct = default)
    {
        if (!await db.Pedidos.AnyAsync(ct))
        {
            var dia = new DateTime(2026, 1, 10, 12, 0, 0, DateTimeKind.Utc);
            for (int i = 1; i <= 60; i++)
            {
                var itens = new List<ItemPedidoRegistro>
                {
                    new() { Produto = "Mouse", Quantidade = 1, PrecoUnitario = 29.90m },
                    new() { Produto = "Teclado", Quantidade = 2, PrecoUnitario = 59.90m }
                };
                db.Pedidos.Add(new PedidoRegistro
                {
                    Id = Guid.Parse($"00000000-0000-0000-0000-{i:D12}"),
                    Status = i % 3 == 0 ? "Concluido" : "Pendente",
                    CriadoEm = dia.AddMinutes(i),
                    Total = itens.Sum(x => x.Quantidade * x.PrecoUnitario),
                    Endereco = new EnderecoEntrega
                    {
                        Cidade = i % 2 == 0 ? "Sao Paulo" : "Campinas",
                        Uf = "SP"
                    },
                    Itens = itens
                });
            }
            await db.SaveChangesAsync(ct);
            db.ChangeTracker.Clear();
        }
        if (!await db.PedidosJson.AnyAsync(ct))
        {
            for (int i = 1; i <= 4; i++)
            {
                db.PedidosJson.Add(new PedidoJsonRegistro
                {
                    Id = Guid.Parse($"10000000-0000-0000-0000-{i:D12}"),
                    Status = "Pendente",
                    Endereco = new EnderecoEntrega { Cidade = "Sao Paulo", Uf = i == 4 ? "RJ" : "SP" }
                });
            }
            await db.SaveChangesAsync(ct);
            db.ChangeTracker.Clear();
        }
    }
}
