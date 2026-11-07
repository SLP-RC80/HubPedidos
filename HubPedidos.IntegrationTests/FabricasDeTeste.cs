extern alias R7;
using System.Data;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using R7DbContext = R7::HubPedidos.Relatorio7.R7DbContext;

namespace HubPedidos.IntegrationTests;

// WAF usa host real R7 em 'Testing' e substitui banco persistente por SQLite :memory:.
// Cada instancia tem sua propria conexao aberta e chaves efemeras locais.
public sealed class FabricaR7 : IDisposable
{
    private readonly string _diretorio;
    private readonly string? _credencialAnterior;
    private readonly string? _arquivoDbAnterior;
    private readonly SqliteConnection _conexao;
    private readonly WebApplicationFactory<R7::Program> _fabrica;

    public string ChaveAlice { get; } = "r8-alice-chave-didatica-temporaria";
    public string ChaveBob { get; } = "r8-bob-chave-didatica-temporaria";
    public R7DbContext CriarDbContext() => CriarEscopo().ServiceProvider.GetRequiredService<R7DbContext>();
    public IServiceScope CriarEscopo() => _fabrica.Services.CreateScope();
    public HttpClient CriarCliente() => _fabrica.CreateClient();
    public DbConnectionEstado Conexao => new(_conexao.State, new SqliteConnectionStringBuilder(_conexao.ConnectionString).DataSource);

    public FabricaR7()
    {
        _diretorio = Path.Combine(Path.GetTempPath(), "hubpedidos-r8-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_diretorio);
        var arquivoChaves = Path.Combine(_diretorio, "tokens.env");
        File.WriteAllLines(arquivoChaves, ["R7_ALICE_KEY=" + ChaveAlice, "R7_BOB_KEY=" + ChaveBob]);
        _credencialAnterior = Environment.GetEnvironmentVariable("R7_CREDENTIALS_FILE");
        _arquivoDbAnterior = Environment.GetEnvironmentVariable("R7_DATABASE_FILE");
        // Necessario antes do codigo de inicializacao original do R7, que le o arquivo de chaves.
        Environment.SetEnvironmentVariable("R7_CREDENTIALS_FILE", arquivoChaves);
        Environment.SetEnvironmentVariable("R7_DATABASE_FILE", Path.Combine(_diretorio, "nao-utilizado.db"));

        _conexao = new SqliteConnection("Data Source=:memory:");
        _conexao.Open();
        _fabrica = new WebApplicationFactory<R7::Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Testing");
            builder.ConfigureTestServices(services =>
            {
                // Remove registros anteriores para que NENHUM DbContext use o banco externo.
                services.RemoveAll<R7DbContext>();
                services.RemoveAll<DbContextOptions<R7DbContext>>();
                services.RemoveAll<IDbContextOptionsConfiguration<R7DbContext>>();
                services.AddDbContext<R7DbContext>(options => options.UseSqlite(_conexao));
            });
        });
    }

    public void Dispose()
    {
        _fabrica.Dispose();
        _conexao.Dispose();
        Environment.SetEnvironmentVariable("R7_CREDENTIALS_FILE", _credencialAnterior);
        Environment.SetEnvironmentVariable("R7_DATABASE_FILE", _arquivoDbAnterior);
        Directory.Delete(_diretorio, recursive: true);
    }
}

public sealed record DbConnectionEstado(ConnectionState Estado, string DataSource);
